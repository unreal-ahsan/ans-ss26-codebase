#include <core.p4>
#include <v1model.p4>

// An L2 switch (dst-mac forwarding) extended with an in-network ARP proxy.
// Hosts in this task are configured to ignore ARP requests, so the switch
// answers them on behalf of every directly-connected host. The controller
// tells us each host's IP -> MAC; the dataplane rewrites an ARP request into
// an ARP reply and bounces it straight back out the port it came in on.

const bit<16> ETH_TYPE_ARP = 0x0806;
const bit<16> ARP_REQUEST = 1;
const bit<16> ARP_REPLY   = 2;
const bit<32> PKT_INSTANCE_TYPE_REPLICATION = 5;

header ethernet_t {
  bit<48> dstAddr;
  bit<48> srcAddr;
  bit<16> etherType;
}

// ARP for IPv4-over-Ethernet (the only flavour we see here)
header arp_t {
  bit<16> hwType;
  bit<16> protoType;
  bit<8>  hwAddrLen;
  bit<8>  protoAddrLen;
  bit<16> opcode;
  bit<48> srcHwAddr;     // sender MAC
  bit<32> srcProtoAddr;  // sender IP
  bit<48> dstHwAddr;     // target MAC
  bit<32> dstProtoAddr;  // target IP (the one being resolved)
}

struct headers_t {
  ethernet_t ethernet;
  arp_t      arp;
}

struct metadata_t { }

parser parse(packet_in pkt, out headers_t hdr,
             inout metadata_t meta, inout standard_metadata_t std) {
  state start {
    pkt.extract(hdr.ethernet);
    transition select(hdr.ethernet.etherType) {
      ETH_TYPE_ARP : parse_arp;
      default      : accept;   // IP & everything else: L2-forward by dst mac
    }
  }
  state parse_arp {
    pkt.extract(hdr.arp);
    transition accept;
  }
}

control ingress(inout headers_t hdr,
                inout metadata_t meta, inout standard_metadata_t std) {

  // ---- L2 forwarding (same as the reference switch) ----
  register<bit<16>>(1) flood_mgid;

  action flood() { flood_mgid.read(std.mcast_grp, 0); }
  action forward(bit<9> port) { std.egress_spec = port; }

  table dmac {
    key            = { hdr.ethernet.dstAddr : exact; }
    actions        = { forward; flood; }
    size           = 4096;
    default_action = flood();
  }

  // ---- ARP proxy ----
  // Turn the request into a reply for `mac` (the MAC that owns the queried IP).
  action arp_reply(bit<48> mac) {
    // The IP being resolved currently sits in arp.dstProtoAddr; remember it
    // before we overwrite that field below.
    bit<32> queried_ip = hdr.arp.dstProtoAddr;

    // Ethernet: send back to whoever asked, from the resolved host.
    hdr.ethernet.dstAddr = hdr.ethernet.srcAddr;
    hdr.ethernet.srcAddr = mac;

    // ARP body: swap requester into the target fields, fill in our answer.
    hdr.arp.opcode       = ARP_REPLY;
    hdr.arp.dstHwAddr    = hdr.arp.srcHwAddr;     // back to requester's MAC
    hdr.arp.dstProtoAddr = hdr.arp.srcProtoAddr;  // back to requester's IP
    hdr.arp.srcHwAddr    = mac;                    // the resolved MAC
    hdr.arp.srcProtoAddr = queried_ip;            // the IP it owns

    // Bounce it back out the port it arrived on.
    std.egress_spec = std.ingress_port;
  }

  table arp_resolve {
    key            = { hdr.arp.dstProtoAddr : exact; }
    actions        = { arp_reply; NoAction; }
    size           = 256;
    default_action = NoAction();
  }

  apply {
    if (hdr.arp.isValid()) {
      // Only requests are expected (hosts never reply). Answer if we can,
      // otherwise drop -- nobody else will.
      if (hdr.arp.opcode == ARP_REQUEST) {
        if (!arp_resolve.apply().hit) {
          mark_to_drop(std);
        }
      } else {
        mark_to_drop(std);
      }
    } else {
      dmac.apply();
    }
  }
}

control egress(inout headers_t hdr,
               inout metadata_t meta, inout standard_metadata_t std) {
  apply {
    // Drop the flooded copy that would loop back out the ingress port.
    if (std.instance_type == PKT_INSTANCE_TYPE_REPLICATION &&
        std.egress_port == std.ingress_port) {
      mark_to_drop(std);
    }
  }
}

control deparse(packet_out pkt, in headers_t hdr) {
  apply {
    pkt.emit(hdr.ethernet);
    pkt.emit(hdr.arp);   // emitted only if valid (ARP packets)
  }
}

control no_checksum(inout headers_t hdr, inout metadata_t meta) { apply {  } }

V1Switch(parse(),no_checksum(),ingress(),egress(),no_checksum(),deparse()) main;
