#include <core.p4>
#include <v1model.p4>

// Hierarchical in-network AllReduce. ONE program, two roles selected by a
// controller-set register:
//
//   role 0 (LEAF/ToR): aggregate local workers' contributions; when all locals
//                      are in, push a PARTIAL up to the spine. On a FINAL coming
//                      back down, fan it out to local workers as a RESULT.
//   role 1 (SPINE):    aggregate the leaves' PARTIALs (treating ToR-id as the
//                      "rank"); when all leaves are in, send the FINAL down.
//
// The aggregation core is identical for both roles -- only the completion action
// differs -- which is why a partial is just a "contribution" one level up.

const bit<16> ETH_TYPE_IPV4 = 0x0800;
const bit<8>  IP_PROTO_UDP   = 17;
const bit<16> SML_PORT       = 9999;

// Switch identity for worker-facing result packets (avoids martian-source drop).
const bit<48> SWITCH_MAC = 0x0000000000FE;   // 00:00:00:00:00:fe
const bit<32> SWITCH_IP  = 0x0A0000FE;       // 10.0.0.254

const bit<8>  TYPE_CONTRIB = 0;   // worker -> leaf
const bit<8>  TYPE_RESULT  = 1;   // leaf   -> worker
const bit<8>  TYPE_PARTIAL = 2;   // leaf   -> spine
const bit<8>  TYPE_FINAL   = 3;   // spine  -> leaf

const bit<32> ROLE_LEAF  = 0;
const bit<32> ROLE_SPINE = 1;

#define CHUNK 8
const bit<32> SLOTS     = 64;
const bit<32> SLOT_MASK = 63;
const bit<32> PKT_INSTANCE_TYPE_REPLICATION = 5;

header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }

header ipv4_t {
  bit<4>  version; bit<4>  ihl; bit<8>  diffserv; bit<16> totalLen;
  bit<16> identification; bit<3> flags; bit<13> fragOffset;
  bit<8>  ttl; bit<8> protocol; bit<16> hdrChecksum;
  bit<32> srcAddr; bit<32> dstAddr;
}

header udp_t { bit<16> srcPort; bit<16> dstPort; bit<16> length; bit<16> checksum; }

header sml_t {
  bit<8>  typ;  bit<8>  op;  bit<16> rank; bit<16> world;
  bit<32> tag;  bit<32> idx;
  int<32> val0; int<32> val1; int<32> val2; int<32> val3;
  int<32> val4; int<32> val5; int<32> val6; int<32> val7;
}

struct headers_t { ethernet_t eth; ipv4_t ipv4; udp_t udp; sml_t sml; }
struct metadata_t { bit<1> is_result; }

parser parse(packet_in pkt, out headers_t hdr,
             inout metadata_t meta, inout standard_metadata_t std) {
  state start {
    pkt.extract(hdr.eth);
    transition select(hdr.eth.etherType) { ETH_TYPE_IPV4 : parse_ipv4; default : accept; }
  }
  state parse_ipv4 {
    pkt.extract(hdr.ipv4);
    transition select(hdr.ipv4.protocol) { IP_PROTO_UDP : parse_udp; default : accept; }
  }
  state parse_udp {
    pkt.extract(hdr.udp);
    transition select(hdr.udp.dstPort) { SML_PORT : parse_sml; default : accept; }
  }
  state parse_sml { pkt.extract(hdr.sml); transition accept; }
}

#define AGG(k) {                                  \
  int<32> v_;                                     \
  val##k.read(v_, addr);                          \
  if (new_round) { v_ = 0; }                      \
  if (!already)  { v_ = v_ + hdr.sml.val##k; }    \
  val##k.write(addr, v_);                         \
  hdr.sml.val##k = v_;                            \
}

control ingress(inout headers_t hdr,
                inout metadata_t meta, inout standard_metadata_t std) {

  // ---- aggregation state ----
  register<bit<64>>(SLOTS) epoch;
  register<bit<32>>(SLOTS) cnt;
  register<bit<32>>(SLOTS) seen;
  register<int<32>>(SLOTS) val0; register<int<32>>(SLOTS) val1;
  register<int<32>>(SLOTS) val2; register<int<32>>(SLOTS) val3;
  register<int<32>>(SLOTS) val4; register<int<32>>(SLOTS) val5;
  register<int<32>>(SLOTS) val6; register<int<32>>(SLOTS) val7;

  // ---- per-switch config (set by the controller) ----
  register<bit<32>>(1) cfg_role;     // 0 leaf, 1 spine
  register<bit<32>>(1) cfg_thr;      // completion threshold (#local workers or #ToRs)
  register<bit<32>>(1) cfg_myid;     // ToR id (leaf only)
  register<bit<32>>(1) cfg_uplink;   // port toward the spine (leaf only)
  register<bit<32>>(1) cfg_dmgid;    // downstream multicast group id

  apply {
    if (!hdr.sml.isValid()) { mark_to_drop(std); return; }

    bit<32> role; cfg_role.read(role, 0);

    bool do_agg = (role == ROLE_LEAF  && hdr.sml.typ == TYPE_CONTRIB) ||
                  (role == ROLE_SPINE && hdr.sml.typ == TYPE_PARTIAL);

    if (do_agg) {
      // ---- shared aggregation core ----
      bit<32> addr = ((bit<32>) hdr.sml.idx) & SLOT_MASK;
      bit<64> ep   = ((bit<64>) hdr.sml.tag << 32) | (bit<64>) hdr.sml.idx;

      bit<64> stored;
      epoch.read(stored, addr);
      bool new_round = (stored != ep);
      epoch.write(addr, ep);

      bit<32> c; bit<32> s;
      cnt.read(c, addr); seen.read(s, addr);
      if (new_round) { c = 0; s = 0; }
      bit<32> rbit = (bit<32>) 1 << (bit<8>) hdr.sml.rank;
      bool already = (s & rbit) != 0;
      if (!already) { s = s | rbit; c = c + 1; }
      cnt.write(addr, c); seen.write(addr, s);

      AGG(0) AGG(1) AGG(2) AGG(3) AGG(4) AGG(5) AGG(6) AGG(7)

      bit<32> thr; cfg_thr.read(thr, 0);
      if (c == thr) {
        if (role == ROLE_LEAF) {
          // locally complete -> push partial up (always, fresh or retransmit)
          hdr.sml.typ = TYPE_PARTIAL;
          bit<32> myid; cfg_myid.read(myid, 0);
          hdr.sml.rank = (bit<16>) myid;       // identify this ToR to the spine
          bit<32> up; cfg_uplink.read(up, 0);
          std.egress_spec = (bit<9>) up;
        } else {
          // globally complete -> send final down
          hdr.sml.typ = TYPE_FINAL;
          meta.is_result = 1;
          if (already) {
            std.egress_spec = std.ingress_port;          // retransmit -> unicast
          } else {
            bit<32> dg; cfg_dmgid.read(dg, 0);
            std.mcast_grp = (bit<16>) dg;                // fresh -> multicast down
          }
        }
      } else {
        mark_to_drop(std);
      }
    } else if (role == ROLE_LEAF && hdr.sml.typ == TYPE_FINAL) {
      // fan the final out to local workers as a result
      hdr.sml.typ      = TYPE_RESULT;
      hdr.udp.checksum = 0;
      hdr.eth.srcAddr  = SWITCH_MAC;
      hdr.ipv4.srcAddr = SWITCH_IP;
      meta.is_result   = 1;
      bit<32> dg; cfg_dmgid.read(dg, 0);
      std.mcast_grp = (bit<16>) dg;
    } else {
      mark_to_drop(std);
    }
  }
}

control egress(inout headers_t hdr,
               inout metadata_t meta, inout standard_metadata_t std) {
  apply {
    if (meta.is_result == 0 &&
        std.instance_type == PKT_INSTANCE_TYPE_REPLICATION &&
        std.egress_port == std.ingress_port) {
      mark_to_drop(std);
    }
  }
}

control deparse(packet_out pkt, in headers_t hdr) {
  apply {
    pkt.emit(hdr.eth); pkt.emit(hdr.ipv4); pkt.emit(hdr.udp); pkt.emit(hdr.sml);
  }
}

control verify_checksum_(inout headers_t hdr, inout metadata_t meta) { apply {  } }

control compute_checksum_(inout headers_t hdr, inout metadata_t meta) {
  apply {
    update_checksum(
      hdr.ipv4.isValid(),
      { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv, hdr.ipv4.totalLen,
        hdr.ipv4.identification, hdr.ipv4.flags, hdr.ipv4.fragOffset,
        hdr.ipv4.ttl, hdr.ipv4.protocol, hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
      hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
  }
}

V1Switch(parse(),verify_checksum_(),ingress(),egress(),compute_checksum_(),deparse()) main;
