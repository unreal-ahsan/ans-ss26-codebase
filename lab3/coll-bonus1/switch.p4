#include <core.p4>
#include <v1model.p4>

// In-network AllReduce via streaming aggregation (SwitchML-style).
//
// Workers send chunk-sized UDP packets to a broadcast address; the switch sums
// them slot by slot and, once every worker has contributed a given chunk,
// returns the aggregated result. Slots are reused across the stream and across
// successive AllReduce calls; an (tag,idx) epoch tag tells the switch when a
// slot is being reused so it can reset it. A per-slot "seen" rank bitmap makes
// retransmitted contributions idempotent, and a completed slot is kept until
// reused so a worker that lost its result can re-request it.

const bit<16> ETH_TYPE_IPV4 = 0x0800;
const bit<8>  IP_PROTO_UDP   = 17;
const bit<16> SML_PORT       = 9999;

// Switch identity for result packets. The source MUST NOT be any worker's
// address, otherwise a worker receives a packet claiming to come from its own
// IP and the kernel drops it as a martian.
const bit<48> SWITCH_MAC = 0x0000000000FE;   // 00:00:00:00:00:fe
const bit<32> SWITCH_IP  = 0x0A0000FE;       // 10.0.0.254

const bit<8>  TYPE_CONTRIB = 0;   // worker -> switch
const bit<8>  TYPE_RESULT  = 1;   // switch -> worker(s)

// Reduction operators. AVG is handled on the worker (SUM, then divide by world),
// so the switch only ever sees SUM/MIN/MAX.
const bit<8>  OP_SUM = 0;
const bit<8>  OP_MIN = 1;
const bit<8>  OP_MAX = 2;

// BMv2 treats a value read from a signed register as unsigned in the next signed
// op, which breaks min/max comparisons. Wrap the register value in SIGNED().
#define SIGNED(bits,var) ((int<bits>)(bit<bits>)var)

// Number of values aggregated per packet (chunk size). Must match the worker.
#define CHUNK 8

// Number of physical aggregation slots. Power of two so addr = idx & MASK.
// Must be >= 2 * worker window so a slot's result is delivered before reuse.
const bit<32> SLOTS     = 64;
const bit<32> SLOT_MASK = 63;

const bit<32> SML_MGID = 1;   // multicast group: all worker ports (== flood grp)
const bit<32> PKT_INSTANCE_TYPE_REPLICATION = 5;

header ethernet_t {
  bit<48> dstAddr;
  bit<48> srcAddr;
  bit<16> etherType;
}

header ipv4_t {
  bit<4>  version;
  bit<4>  ihl;
  bit<8>  diffserv;
  bit<16> totalLen;
  bit<16> identification;
  bit<3>  flags;
  bit<13> fragOffset;
  bit<8>  ttl;
  bit<8>  protocol;
  bit<16> hdrChecksum;
  bit<32> srcAddr;
  bit<32> dstAddr;
}

header udp_t {
  bit<16> srcPort;
  bit<16> dstPort;
  bit<16> length;
  bit<16> checksum;
}

header sml_t {
  bit<8>  typ;
  bit<8>  op;
  bit<16> rank;
  bit<16> world;
  bit<32> tag;
  bit<32> idx;
  int<32> val0;
  int<32> val1;
  int<32> val2;
  int<32> val3;
  int<32> val4;
  int<32> val5;
  int<32> val6;
  int<32> val7;
}

struct headers_t {
  ethernet_t eth;
  ipv4_t     ipv4;
  udp_t      udp;
  sml_t      sml;
}

struct metadata_t {
  bit<1> is_result;   // skip the flood-loopback drop for result multicasts
}

parser parse(packet_in pkt, out headers_t hdr,
             inout metadata_t meta, inout standard_metadata_t std) {
  state start {
    pkt.extract(hdr.eth);
    transition select(hdr.eth.etherType) {
      ETH_TYPE_IPV4 : parse_ipv4;
      default       : accept;
    }
  }
  state parse_ipv4 {
    pkt.extract(hdr.ipv4);
    transition select(hdr.ipv4.protocol) {
      IP_PROTO_UDP : parse_udp;
      default      : accept;
    }
  }
  state parse_udp {
    pkt.extract(hdr.udp);
    transition select(hdr.udp.dstPort) {
      SML_PORT : parse_sml;
      default  : accept;
    }
  }
  state parse_sml {
    pkt.extract(hdr.sml);
    transition accept;
  }
}

// Read slot k, reset on a new round, add this packet's contribution (unless this
// rank was already counted), write back, and stamp the running sum into the
// packet so it carries the result if the slot completes.
// The first contributor of a round seeds the slot with its own value (correct
// for min/max, and identical to 0+val for sum); later contributors apply the op.
#define AGG(k) {                                                                     \
  int<32> v_;                                                                        \
  val##k.read(v_, addr);                                                             \
  if (!already) {                                                                    \
    if (first)       { v_ = hdr.sml.val##k; }                                        \
    else if (op_min) { if (hdr.sml.val##k < SIGNED(32, v_)) { v_ = hdr.sml.val##k; } } \
    else if (op_max) { if (hdr.sml.val##k > SIGNED(32, v_)) { v_ = hdr.sml.val##k; } } \
    else             { v_ = SIGNED(32, v_) + hdr.sml.val##k; }                       \
  }                                                                                  \
  val##k.write(addr, v_);                                                            \
  hdr.sml.val##k = v_;                                                               \
}

control ingress(inout headers_t hdr,
                inout metadata_t meta, inout standard_metadata_t std) {

  // ---- aggregation state (one entry per slot) ----
  register<bit<64>>(SLOTS) epoch;   // (tag<<32 | idx) currently in the slot
  register<bit<32>>(SLOTS) cnt;     // distinct contributors so far
  register<bit<32>>(SLOTS) seen;    // bitmap of ranks that contributed
  register<int<32>>(SLOTS) val0;
  register<int<32>>(SLOTS) val1;
  register<int<32>>(SLOTS) val2;
  register<int<32>>(SLOTS) val3;
  register<int<32>>(SLOTS) val4;
  register<int<32>>(SLOTS) val5;
  register<int<32>>(SLOTS) val6;
  register<int<32>>(SLOTS) val7;

  // ---- L2 forwarding for normal (non-SML) traffic ----
  register<bit<16>>(1) flood_mgid;
  action flood() { flood_mgid.read(std.mcast_grp, 0); }
  action forward(bit<9> port) { std.egress_spec = port; }
  table dmac {
    key            = { hdr.eth.dstAddr : exact; }
    actions        = { forward; flood; }
    size           = 4096;
    default_action = flood();
  }

  apply {
    if (hdr.sml.isValid() && hdr.sml.typ == TYPE_CONTRIB) {
      bit<32> addr = ((bit<32>) hdr.sml.idx) & SLOT_MASK;
      bit<64> ep   = ((bit<64>) hdr.sml.tag << 32) | (bit<64>) hdr.sml.idx;

      // epoch: detect slot reuse (new chunk and/or new AllReduce call)
      bit<64> stored;
      epoch.read(stored, addr);
      bool new_round = (stored != ep);
      epoch.write(addr, ep);

      // count + dedup
      bit<32> c;
      bit<32> s;
      cnt.read(c, addr);
      seen.read(s, addr);
      if (new_round) { c = 0; s = 0; }
      bit<32> rbit = (bit<32>) 1 << (bit<8>) hdr.sml.rank;
      bool already = (s & rbit) != 0;
      bool first   = (!already) && (c == 0);   // first contributor this round
      if (!already) { s = s | rbit; c = c + 1; }
      cnt.write(addr, c);
      seen.write(addr, s);

      // per-op aggregation of all CHUNK values
      bool op_min = (hdr.sml.op == OP_MIN);
      bool op_max = (hdr.sml.op == OP_MAX);
      AGG(0) AGG(1) AGG(2) AGG(3) AGG(4) AGG(5) AGG(6) AGG(7)

      // complete when every worker has contributed this chunk
      if (c == (bit<32>) hdr.sml.world) {
        hdr.sml.typ   = TYPE_RESULT;
        hdr.udp.checksum = 0;          // payload changed; disable UDP checksum
        meta.is_result = 1;
        hdr.eth.srcAddr  = SWITCH_MAC; // sender is "the switch", not a worker
        hdr.ipv4.srcAddr = SWITCH_IP;  // avoids martian-source drop at the worker
        if (already) {
          std.egress_spec = std.ingress_port;   // retransmit -> unicast back
        } else {
          std.mcast_grp = (bit<16>) SML_MGID;    // just completed -> multicast
        }
      } else {
        mark_to_drop(std);             // contribution consumed, nothing to send
      }
    } else if (hdr.sml.isValid()) {
      mark_to_drop(std);               // stray result arriving at the switch
    } else {
      dmac.apply();                    // normal L2 traffic
    }
  }
}

control egress(inout headers_t hdr,
               inout metadata_t meta, inout standard_metadata_t std) {
  apply {
    // Drop the flooded copy looping back out its own ingress port -- but NOT
    // for result multicasts, where the ingress worker also needs the result.
    if (meta.is_result == 0 &&
        std.instance_type == PKT_INSTANCE_TYPE_REPLICATION &&
        std.egress_port == std.ingress_port) {
      mark_to_drop(std);
    }
  }
}

control deparse(packet_out pkt, in headers_t hdr) {
  apply {
    pkt.emit(hdr.eth);
    pkt.emit(hdr.ipv4);
    pkt.emit(hdr.udp);
    pkt.emit(hdr.sml);
  }
}

control verify_checksum_(inout headers_t hdr, inout metadata_t meta) { apply {  } }

// We rewrite ipv4.srcAddr for results, so the IP header checksum must be
// recomputed. (For untouched packets this recomputes to the same value.)
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
