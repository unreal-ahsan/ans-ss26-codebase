#include <core.p4>
#include <v1model.p4>

// An in-network calculator. The client sends a calc request (custom L3 protocol
// directly over Ethernet); the switch performs the op and sends the result back
// in field `a`. A signed 32-bit memory cell `mem` backs the memory ops. All
// non-calc traffic is L2-forwarded normally.

const bit<16> ETH_TYPE_CALC = 0x1234;
const bit<32> PKT_INSTANCE_TYPE_REPLICATION = 5;

// opcodes (must match util/calculator.py Op)
const bit<8> OP_ADD    = 1;
const bit<8> OP_MIN    = 2;
const bit<8> OP_MAX    = 3;
const bit<8> OP_NEG    = 4;
const bit<8> OP_SHL    = 5;
const bit<8> OP_SHR    = 6;
const bit<8> OP_MSTORE = 11;
const bit<8> OP_MLOAD  = 12;
const bit<8> OP_MADD   = 13;
const bit<8> OP_MMIN   = 14;
const bit<8> OP_MMAX   = 15;
const bit<8> OP_MNEG   = 16;
const bit<8> OP_MSHL   = 17;
const bit<8> OP_MSHR   = 18;

header ethernet_t {
  bit<48> dstAddr;
  bit<48> srcAddr;
  bit<16> etherType;
}

header calc_t {
  bit<8>  op;
  int<32> a;
  int<32> b;
}

struct headers_t {
  ethernet_t eth;
  calc_t     calc;
}

struct metadata_t { }

parser parse(packet_in pkt, out headers_t hdr,
             inout metadata_t meta, inout standard_metadata_t std) {
  state start {
    pkt.extract(hdr.eth);
    transition select(hdr.eth.etherType) {
      ETH_TYPE_CALC : parse_calc;
      default       : accept;
    }
  }
  state parse_calc {
    pkt.extract(hdr.calc);
    transition accept;
  }
}

// === IMPORTANT NOTE (from the template) ===
// BMv2 treats a value read from a SIGNED register as unsigned in the next signed
// operation, which breaks comparisons/shifts. Wrap such values in SIGNED().
#define SIGNED(bits,var) ((int<bits>)(bit<bits>)var)

control calculator(inout headers_t hdr, inout metadata_t meta,
                   inout standard_metadata_t std) {

  // The switch's single signed memory cell.
  register<int<32>>(1) mem;

  // NOTE: bmv2 actions cannot contain conditionals, so the per-op logic lives
  // here in apply(). min/max need a real comparison (branchless subtraction
  // would overflow on e.g. INT_MIN/INT_MAX), so they must branch.
  apply {
    if (hdr.calc.op >= OP_MSTORE) {
      // ---- memory ops: result returned is the OLD mem value ----
      int<32> m;
      mem.read(m, 0);
      int<32> old = m;            // value to return (raw bits, value-preserving)
      int<32> a   = hdr.calc.a;

      if      (hdr.calc.op == OP_MSTORE) { m = a; }
      else if (hdr.calc.op == OP_MLOAD)  { /* read only */ }
      else if (hdr.calc.op == OP_MADD)   { m = SIGNED(32, m) + a; }
      else if (hdr.calc.op == OP_MMIN)   { if (a < SIGNED(32, m)) { m = a; } }
      else if (hdr.calc.op == OP_MMAX)   { if (a > SIGNED(32, m)) { m = a; } }
      else if (hdr.calc.op == OP_MNEG)   { m = -SIGNED(32, m); }
      else if (hdr.calc.op == OP_MSHL)   { m = SIGNED(32, m) << 1; }
      else if (hdr.calc.op == OP_MSHR)   { m = SIGNED(32, m) >> 1; }

      mem.write(0, m);
      hdr.calc.a = old;           // MLOAD: old == current, so returns mem too
    } else {
      // ---- arithmetic ops: result in a ----
      if      (hdr.calc.op == OP_ADD) { hdr.calc.a = hdr.calc.a + hdr.calc.b; }
      else if (hdr.calc.op == OP_MIN) { if (hdr.calc.b < hdr.calc.a) { hdr.calc.a = hdr.calc.b; } }
      else if (hdr.calc.op == OP_MAX) { if (hdr.calc.b > hdr.calc.a) { hdr.calc.a = hdr.calc.b; } }
      else if (hdr.calc.op == OP_NEG) { hdr.calc.a = -hdr.calc.a; }
      else if (hdr.calc.op == OP_SHL) { hdr.calc.a = hdr.calc.a << 1; }
      else if (hdr.calc.op == OP_SHR) { hdr.calc.a = SIGNED(32, hdr.calc.a) >> 1; }
    }
  }
}

control ingress(inout headers_t hdr, inout metadata_t meta,
                inout standard_metadata_t std) {
  calculator() calc;

  // ---- L2 forwarding for non-calc traffic ----
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
    if (hdr.calc.isValid()) {
      calc.apply(hdr, meta, std);
      // reflect the response back to the client out the port it came in on
      bit<48> tmp        = hdr.eth.srcAddr;
      hdr.eth.srcAddr    = hdr.eth.dstAddr;
      hdr.eth.dstAddr    = tmp;
      std.egress_spec    = std.ingress_port;
    } else {
      dmac.apply();
    }
  }
}

control egress(inout headers_t hdr, inout metadata_t meta,
               inout standard_metadata_t std) {
  apply {
    // drop the flooded copy looping back out its own ingress port
    if (std.instance_type == PKT_INSTANCE_TYPE_REPLICATION &&
        std.egress_port == std.ingress_port) {
      mark_to_drop(std);
    }
  }
}

control deparse(packet_out pkt, in headers_t hdr) {
  apply {
    pkt.emit(hdr.eth);
    pkt.emit(hdr.calc);
  }
}

control no_checksum(inout headers_t hdr, inout metadata_t meta) { apply {  } }

V1Switch(parse(),no_checksum(),ingress(),egress(),no_checksum(),deparse()) main;
