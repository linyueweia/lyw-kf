#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
merge-dtb.py -- merge the fnOS 6.18 native NanoPi R5S expanded DTS (skeleton) with the
                KICKPI K1 live vendor DTS (board) into a self-contained, #include-free
                DTS/DTB for the KICKPI K1 V1.2 (RK3568B2).

Inputs  (dtb-work/):
  r5s.dts       fnOS 6.18 native NanoPi R5S expanded DTS   -- skeleton (SoC truth)
  k1-live.dts   KICKPI K1 live vendor (5.10) expanded DTS  -- board truth

Outputs (same dir):
  rk3568-kickpi-k1.dts / .dtb

Method (same idea as the sister project's LYT T68M product):
  1. Nodes are paired by ADDRESS (@addr), never by name (dwmmc@fe000000 == mmc@fe000000).
  2. SoC-level values (clocks / resets / opp / power-domains / iommu / npu / nvmem /
     interrupt-map / reg ...) are ALWAYS kept from the skeleton; the vendor 5.10 tree
     never overwrites 6.18 values.
  3. Only board-level content is taken from the live board tree.
  4. Board phandle references are re-targeted into the skeleton's phandle space by
     resolving board-phandle -> board-node-path -> matching skeleton node.  Nodes that
     exist only on the board are imported with a freshly allocated phandle.  Phandle
     translation is positional per property (see cell_rule) so that non-reference
     numbers (clock ids, gpio pin numbers, flags, reg values) are never mis-mapped.
  5. #include-free; reproducible by any dtc.

Usage:
  python3 merge-dtb.py            # rebuild rk3568-kickpi-k1.dts/.dtb and validate
"""
import os
import re
import sys
import hashlib
import subprocess
import collections

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "dtb-work")
SKELETON = os.path.join(WORK, "r5s.dts")
BOARD = os.path.join(WORK, "k1-live.dts")
OUT_DTS = os.path.join(WORK, "rk3568-kickpi-k1.dts")
OUT_DTB = os.path.join(WORK, "rk3568-kickpi-k1.dtb")


# =========================================================================== #
# DTS model + parser
# =========================================================================== #
class Node:
    __slots__ = ("name", "label", "props", "children", "parent")

    def __init__(self, name, label=None, parent=None):
        self.name = name
        self.label = label
        self.props = collections.OrderedDict()
        self.children = collections.OrderedDict()
        self.parent = parent

    def addrkey(self):
        return "@" + self.name.rsplit("@", 1)[1] if "@" in self.name else self.name

    def path(self):
        segs, n = [], self
        while n is not None and n.parent is not None:
            segs.append(n.addrkey()); n = n.parent
        return "/" + "/".join(reversed(segs))

    def pretty(self):
        segs, n = [], self
        while n is not None and n.parent is not None:
            segs.append(n.name); n = n.parent
        return "/" + "/".join(reversed(segs))

    def walk(self):
        yield self
        for c in self.children.values():
            yield from c.walk()

    def find(self, name):
        if name in self.children:
            return self.children[name]
        ak = "@" + name.rsplit("@", 1)[1] if "@" in name else name
        hits = [c for c in self.children.values() if c.addrkey() == ak]
        return hits[0] if len(hits) == 1 else None

    def del_child(self, name):
        self.children.pop(name, None)


class Value:
    __slots__ = ("chunks",)

    def __init__(self, chunks=None):
        self.chunks = chunks or []

    def cells(self):
        for k, v in self.chunks:
            if k == "cells":
                return v
        return None

    def strings(self):
        return [v for k, v in self.chunks if k == "str"]


TOKEN_RE = re.compile(r"""
      (?P<ws>[ \t\r\n]+)
    | (?P<bcomment>/\*.*?\*/)
    | (?P<lcomment>//[^\n]*)
    | (?P<root>/dts-v1/|/memreserve/|/delete-node/|/delete-property/)
    | (?P<string>"(?:[^"\\]|\\.)*")
    | (?P<bytes>\[[0-9a-fA-F\s]*\])
    | (?P<num>0[xX][0-9a-fA-F]+|[0-9]+)
    | (?P<name>[A-Za-z_#][A-Za-z0-9_.,+@\-]*)
    | (?P<punct>[{}<>\[\];:,=/])
""", re.X | re.S)


def tokenize(text):
    pos, end, toks = 0, len(text), []
    while pos < end:
        m = TOKEN_RE.match(text, pos)
        if not m:
            raise ValueError("lex error at %d: %r" % (pos, text[pos:pos + 40]))
        pos = m.end()
        if m.lastgroup in ("ws", "bcomment", "lcomment"):
            continue
        toks.append((m.lastgroup, m.group()))
    return toks


class Parser:
    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def next(self):
        v = self.peek(); self.i += 1; return v

    def expect(self, val):
        k, s = self.next()
        if s != val:
            raise ValueError("expected %r got %r at tok %d" % (val, s, self.i - 1))

    def parse(self):
        k, s = self.next()
        if s != "/dts-v1/":
            raise ValueError("missing /dts-v1/")
        self.expect(";")
        root = Node("")
        while True:
            k, s = self.peek()
            if s == "/memreserve/":
                self.next()
                while self.next()[1] != ";":
                    pass
            elif s == "/":
                break
            else:
                raise ValueError("unexpected token %r" % s)
        self.expect("/"); self.expect("{")
        self.parse_body(root)
        self.expect("}"); self.expect(";")
        return root

    def parse_cells(self):
        self.expect("<"); vals = []
        while True:
            k, s = self.peek()
            if s == ">":
                self.next(); break
            k, s = self.next()
            if k == "num":
                vals.append(int(s, 0))
            else:
                raise ValueError("unexpected in cells: %r" % s)
        return vals

    def parse_value(self):
        val = Value()
        while True:
            k, s = self.peek()
            if s == "<":
                val.chunks.append(("cells", self.parse_cells()))
            elif k == "string":
                self.next(); val.chunks.append(("str", s[1:-1]))
            elif k == "bytes":
                self.next(); val.chunks.append(("bytes", [int(x, 16) for x in s[1:-1].split()]))
            else:
                raise ValueError("bad value token %r" % s)
            k, s = self.peek()
            if s == ",":
                self.next(); continue
            break
        return val

    def parse_body(self, node):
        while True:
            k, s = self.peek()
            if s == "}":
                return
            lbl = None
            if k == "name" and self.t[self.i + 1][1] == ":":
                lbl = self.next()[1]; self.next()
                k, s = self.peek()
            if s in ("/delete-node/", "/delete-property/"):
                raise ValueError("delete directives unsupported")
            k, s = self.next()
            if k != "name":
                raise ValueError("expected name, got %r" % (s,))
            name = s
            k2, s2 = self.peek()
            if s2 == "{":
                self.next()
                child = Node(name, lbl, node)
                node.children[child.name] = child
                self.parse_body(child)
                self.expect("}"); self.expect(";")
            elif s2 == "=":
                self.next(); node.props[name] = self.parse_value(); self.expect(";")
            elif s2 == ";":
                self.next(); node.props[name] = Value()
            else:
                raise ValueError("bad body token %r after %r" % (s2, name))


def parse_file(path):
    return Parser(tokenize(open(path, encoding="utf-8", errors="replace").read())).parse()


def deep_copy(node, parent=None):
    n = Node(node.name, node.label, parent)
    for k, v in node.props.items():
        n.props[k] = Value(list(v.chunks))
    for c in node.children.values():
        n.children[c.name] = deep_copy(c, n)
    return n


# =========================================================================== #
# emitter
# =========================================================================== #
def fmt_cells(vals):
    return "<" + " ".join("0x%02x" % (v & 0xffffffff) for v in vals) + ">"


def fmt_value(val):
    out = []
    for kind, v in val.chunks:
        if kind == "cells":
            out.append(fmt_cells(v))
        elif kind == "str":
            out.append('"%s"' % v)
        elif kind == "bytes":
            out.append("[" + " ".join("%02x" % b for b in v) + "]")
    return ", ".join(out)


def emit(node, depth, lines):
    name = node.name if node.name != "" else "/"
    ind = "\t" * depth
    pre = (node.label + ": ") if node.label else ""
    lines.append("%s%s%s {" % (ind, pre, name))
    for pname, pval in node.props.items():
        body = ("%s = %s;" % (pname, fmt_value(pval))) if pval.chunks else (pname + ";")
        lines.append("\t" * (depth + 1) + body)
    for c in node.children.values():
        emit(c, depth + 1, lines)
    lines.append("%s};" % ind)
    lines.append("")


# =========================================================================== #
# merge configuration
# =========================================================================== #
# Kept from the skeleton whenever a board node is merged into an existing skeleton node.
SOC_DENY = {
    "compatible", "reg", "reg-names", "device_type", "ranges",
    "#address-cells", "#size-cells", "#interrupt-cells", "#clock-cells",
    "clocks", "clock-names", "assigned-clocks", "assigned-clock-parents",
    "assigned-clock-rates", "resets", "reset-names", "power-domains",
    "interrupts", "interrupt-names", "interrupt-parent", "interrupt-affinity",
    "interrupt-map", "interrupt-map-mask", "iommus",
    "operating-points", "operating-points-v2", "nvmem-cells", "nvmem-cell-names",
    "dmas", "dma-names", "msi-map", "linux,pci-domain",
    "num-ib-windows", "num-ob-windows", "bus-range", "rockchip,pmu",
}

# board top-level nodes merged into the matching skeleton node (paired by @addr)
MERGE_BY_ADDR = [
    "@fe2a0000", "@fe010000",                              # gmac0 / gmac1
    "@fc000000", "@fc400000", "@fc800000",                 # sata x3
    "@fd800000", "@fd840000", "@fd880000", "@fd8c0000",    # USB2 EHCI/OHCI x4
    "@fe000000", "@fe2b0000", "@fe2c0000", "@fe310000",    # sdmmc2 / sd / sdio2 / emmc
    "@fe260000", "@fe270000", "@fe280000",                 # pcie3x1 / pcie3x2
    "@fdd40000",                                           # i2c0 -- PMIC + TCS4525
    "@fe5d0000", "@fe5e0000",                              # i2c4 (gc5035) / i2c5 (hym8563)
    "@fe720000",                                           # saradc (keys)
]

# board top-level nodes merged into a skeleton top-level node of the SAME name
MERGE_BY_NAME = ["reserved-memory", "adc-keys", "hdmi-sound", "rockchip-system-monitor"]

# board glue node -> output node name (skeleton combined dwc3 node is replaced)
RENAME = {"usbdrd": ("usb@fcc00000", "usbdrd30"),
          "usbhost": ("usb@fd000000", "usbhost30")}

# skeleton top-level board nodes dropped (R5S-only)
DELETE_TOP = ["hdmi-con", "gpio-leds", "gpio-keys", "regulator-vdd-usbc"]

# board-only top-level nodes added to the output
ADD_BOARD_TOP = [
    "memory", "sdio-pwrseq", "wireless-wlan", "wireless-bluetooth",
    "leds", "fiq-debugger", "rk809-sound", "dummy-codec",
    "dc-12v", "vcc2v5-ddr", "vcc3v3-bu",
    "gpio-regulator", "pcie3-regulator", "minipcie-regulator",
]

# board regulator merged into an existing skeleton regulator node so that the
# skeleton's internal references stay valid : board_name -> skeleton_name
REGULATOR_MAP = {
    "vcc3v3-sys": "regulator-vcc3v3-sys",
    "vcc5v0-sys": "regulator-vcc5v0-sys",
    "vcc5v0-usb": "regulator-vcc5v0-usb",
    "vcc5v0-host-regulator": "regulator-vcc5v0-usb-host",
    "vcc5v0-otg-regulator": "regulator-vcc5v0-usb-otg",
}

# paths whose child set is fully REPLACED by the board's (gmac mdio -> maxio phy)
REPLACE_CHILDREN = {"/@fe2a0000", "/@fe010000"}

# skeleton child nodes removed after merge : (parent addrkey-path, child name)
DELETE_CHILD = [("/adc-keys", "button-maskrom"),
                # R5S HDMI connector is dropped; also drop the hdmi port that pointed
                # at it so no phandle is left dangling.
                ("/@fe0a0000/ports", "port@1")]

# board children to skip entirely (so their reference chains are not imported)
SKIP_CHILDREN = {
    # gc5035 kept as an i2c device, but its MIPI-CSI port is dropped: the fnOS 6.18
    # R5S skeleton has no csi2-dphy/rkisp/rkcif infra and importing the vendor 5.10
    # CSI nodes would pollute 6.18 (iron rule #1).
    ("/@fe5d0000/@37", "port"),
}

MAXIO_PHY_COMPAT = ["maxio,mae0621a", "ethernet-phy-ieee802.3-c22"]

# explicit board status overrides applied after the merge (path -> status)
# 铁律：以实机为准。实机 DT 里 sata@fc000000=okay，另两个是 disabled（K1 只有一个 SATA 口）。
# 之前为满足错误的任务断言把三个都写成 okay，已纠正。
FORCE_STATUS = {"/@fc000000": "okay", "/@fc400000": "disabled", "/@fc800000": "disabled"}

# labels attached to PMIC regulators (for __symbols__ / DTS readability)
REG_LABELS = {"/@fdd40000/@20/regulators/DCDC_REG1": "vdd_logic",
              "/@fdd40000/@20/regulators/DCDC_REG2": "vdd_gpu",
              "/@fdd40000/@20/regulators/DCDC_REG3": "vcc_ddr",
              "/@fdd40000/@20/regulators/DCDC_REG4": "vdd_npu"}


# =========================================================================== #
# phandle translation rules (positional, so ids/flags/regs are never touched)
# =========================================================================== #
def cell_rule(pname):
    if pname.startswith("pinctrl-") and pname != "pinctrl-names":
        return "all"
    if pname.endswith("-supply"):
        return "all"
    if pname.endswith("-gpios") or pname == "gpios" or pname.endswith("-gpio"):
        return "first"
    if pname in ("extcon", "phy-handle", "rockchip,grf", "rockchip,pipe-grf",
                 "rockchip,pipe-phy-grf", "remote-endpoint", "memory-region", "devfreq",
                 "rockchip,hw", "rockchip,cif", "snps,axi-config",
                 "snps,mtl-rx-config", "snps,mtl-tx-config",
                 "simple-audio-card,bitclock-master", "simple-audio-card,frame-master"):
        return "all"
    if pname in ("power-domains", "assigned-clocks", "assigned-clock-parents",
                 "phys", "resets", "iommus", "dmas",
                 "nvmem-cells", "clocks", "io-channels", "interconnects",
                 "sound-dai", "rockchip,cpu", "rockchip,codec"):
        return "even"
    if pname == "interrupt-parent":
        return "first"
    return "none"


class Merger:
    def __init__(self, skel, board):
        self.S, self.B = skel, board
        self.out = deep_copy(skel)
        for n in self.out.walk():
            n.parent = n.parent  # parent links already set by deep_copy
        self.out_by_path = {n.path(): n for n in self.out.walk()}
        self.sph = {n.props["phandle"].cells()[0]: n for n in skel.walk()
                    if "phandle" in n.props and n.props["phandle"].cells()}
        self.bph = {n.props["phandle"].cells()[0]: n for n in board.walk()
                    if "phandle" in n.props and n.props["phandle"].cells()}
        self.nextph = (max(self.sph) if self.sph else 0) + 1
        self.memo = {}
        self.stats = collections.Counter()
        self.missed = []

    # ---- phandles ---------------------------------------------------------
    def phandle_of(self, o):
        c = o.props.get("phandle")
        if c is not None and c.cells():
            return c.cells()[0]
        v = self.nextph; self.nextph += 1
        o.props["phandle"] = Value([("cells", [v])])
        return v

    def map_cell(self, v):
        bn = self.bph.get(v)
        if bn is None:
            return v
        return self.phandle_of(self.resolve(bn))

    def tr_value(self, val, pname):
        rule = cell_rule(pname)
        if rule == "none":
            return Value(list(val.chunks))
        out = []
        for kind, chunks in val.chunks:
            if kind != "cells":
                out.append((kind, chunks)); continue
            new = list(chunks)
            if rule == "all":
                idxs = range(len(new))
            elif rule == "even":
                idxs = range(0, len(new), 2)
            else:
                idxs = [0] if new else []
            for i in idxs:
                new[i] = self.map_cell(new[i])
            out.append(("cells", new))
        return Value(out)

    # ---- resolve / import -------------------------------------------------
    def resolve(self, bnode):
        if id(bnode) in self.memo:
            return self.memo[id(bnode)]
        o = self.out_by_path.get(bnode.path())
        if o is not None:
            self.memo[id(bnode)] = o
            return o
        return self.import_node(bnode)

    def _copy_board_node(self, bnode, onode):
        self.memo[id(bnode)] = onode
        self.out_by_path[onode.path()] = onode
        for k, v in bnode.props.items():
            if k == "phandle":
                continue
            onode.props[k] = self.tr_value(v, k)
        for c in bnode.children.values():
            if (onode.path(), c.name) in SKIP_CHILDREN:
                continue
            self.import_node_under(c, onode)
        self.stats["imported"] += 1
        return onode

    def import_node_under(self, bnode, onode):
        o = Node(bnode.name, None, onode)
        onode.children[bnode.name] = o
        return self._copy_board_node(bnode, o)

    def import_node(self, bnode):
        bp = bnode.parent
        parent_out = self.out if (bp is None or bp.name == "") else self.resolve(bp)
        o = Node(bnode.name, None, parent_out)
        parent_out.children[bnode.name] = o
        return self._copy_board_node(bnode, o)

    # ---- merge ------------------------------------------------------------
    def merge_node(self, bnode, onode):
        self.memo[id(bnode)] = onode
        for k, v in bnode.props.items():
            if k == "phandle" or k in SOC_DENY:
                continue
            onode.props[k] = self.tr_value(v, k)
            self.stats["override_prop"] += 1
        for c in bnode.children.values():
            if (onode.path(), c.name) in SKIP_CHILDREN:
                continue
            oc = onode.find(c.name)
            if oc is None:
                self.import_node_under(c, onode)
            else:
                self.merge_node(c, oc)

    def replace_children(self, bnode, onode):
        for c in list(onode.children.values()):
            for p in list(self.out_by_path):
                if p == c.path() or p.startswith(c.path() + "/"):
                    self.out_by_path.pop(p, None)
        onode.children.clear()
        for c in bnode.children.values():
            self.import_node_under(c, onode)

    # ---- top-level driver -------------------------------------------------
    def run(self):
        b_by = {c.addrkey(): c for c in self.B.children.values()}
        s_by = {c.addrkey(): c for c in self.out.children.values()}

        # pre-register memo for board nodes that merge into a skeleton node whose
        # name differs, so any reference resolved during the merge is mapped to the
        # skeleton node instead of importing a duplicate top-level node.
        for bname, skname in REGULATOR_MAP.items():
            bn, on = self.B.children.get(bname), self.out.children.get(skname)
            if bn is not None and on is not None:
                self.memo[id(bn)] = on

        # USB glue: replace the skeleton combined node with board glue + dwc3 child
        # (run before other merges so references to the board glue resolve to it)
        for bname, (skname, newname) in RENAME.items():
            bn = self.B.children.get(bname)
            if bn is None:
                continue
            old = self.out.children.get(skname)
            if old is not None:
                for p in list(self.out_by_path):
                    if p == old.path() or p.startswith(old.path() + "/"):
                        self.out_by_path.pop(p, None)
                self.out.children.pop(skname, None)
            o = Node(newname, None, self.out)
            self.out.children[newname] = o
            self._copy_board_node(bn, o)
            self.stats["usb_split"] += 1

        for ak in MERGE_BY_ADDR:
            bn, on = b_by.get(ak), s_by.get(ak)
            if bn is None or on is None:
                self.missed.append("addr " + ak); continue
            if on.path() in REPLACE_CHILDREN:
                self.replace_children(bn, on)
            self.merge_node(bn, on)
            self.stats["merged_addr"] += 1

        for nm in MERGE_BY_NAME:
            bn, on = self.B.children.get(nm), self.out.children.get(nm)
            if bn is None or on is None:
                self.missed.append("name " + nm); continue
            self.merge_node(bn, on)
            self.stats["merged_name"] += 1

        # remaining board top-level nodes (regulators mapped, others added/merged)
        handled = set(MERGE_BY_ADDR) | set(MERGE_BY_NAME) | set(RENAME)
        for nm in ADD_BOARD_TOP + list(REGULATOR_MAP):
            bn = self.B.children.get(nm)
            if bn is None:
                self.missed.append("add " + nm); continue
            skname = REGULATOR_MAP.get(nm)
            if skname and skname in self.out.children:
                self.merge_node(bn, self.out.children[skname])
                self.stats["merged_reg"] += 1
            elif nm in self.out.children:
                self.merge_node(bn, self.out.children[nm])
                self.stats["merged_reg"] += 1
            else:
                self.import_node_under(bn, self.out)
                self.stats["added"] += 1

        for nm in DELETE_TOP:
            if self.out.children.pop(nm, None) is not None:
                self.stats["deleted_top"] += 1
        for parent_path, child in DELETE_CHILD:
            pn = self.out_by_path.get(parent_path)
            if pn is not None and pn.del_child(child) is None:
                pass

        self._annotate_maxio()
        for path, st in FORCE_STATUS.items():
            n = self.out_by_path.get(path)
            if n is not None:
                n.props["status"] = Value([("str", st)])
        for path, lab in REG_LABELS.items():
            n = self.out_by_path.get(path)
            if n is not None and not n.label:
                n.label = lab
        self._annotate_aliases()
        return self.out

    # ---- annotate ---------------------------------------------------------
    def _annotate_maxio(self):
        for ak in ("/@fe2a0000", "/@fe010000"):
            n = self.out_by_path.get(ak)
            mdio = n.find("mdio") if n else None
            if not mdio:
                continue
            for phy in mdio.children.values():
                if phy.name.startswith("ethernet-phy") or phy.name.startswith("phy@"):
                    phy.props["compatible"] = Value([("str", c) for c in MAXIO_PHY_COMPAT])

    @staticmethod
    def _find_path(root, path):
        if not path.startswith("/"):
            return None
        n = root
        for seg in path.strip("/").split("/"):
            if not seg:
                continue
            n = n.find(seg)
            if n is None:
                return None
        return n

    def _annotate_aliases(self):
        al = self.out.children.get("aliases")
        if not al:
            return
        newprops = collections.OrderedDict()
        for src in (self.B.children.get("aliases"), self.S.children.get("aliases")):
            if not src:
                continue
            for k, v in src.props.items():
                if k in newprops:
                    continue
                s = v.strings()
                if not s:
                    continue
                on = self._find_path(self.out, s[0])
                if on is not None and on is not self.out:
                    newprops[k] = Value([("str", on.pretty())])
        al.props = newprops


# =========================================================================== #
# validation
# =========================================================================== #
def validate(root):
    issues = []
    ph = {}
    for n in root.walk():
        c = n.props.get("phandle")
        if c is not None and c.cells():
            v = c.cells()[0]
            if v in ph:
                issues.append("duplicate phandle 0x%x: %s vs %s" % (v, ph[v], n.pretty()))
            ph[v] = n.pretty()
    for n in root.walk():
        for pname, v in n.props.items():
            rule = cell_rule(pname)
            if rule == "none" or not v.chunks:
                continue
            cells = v.cells()
            if not cells:
                continue
            idxs = range(len(cells)) if rule == "all" else (
                range(0, len(cells), 2) if rule == "even" else ([0] if cells else []))
            for i in idxs:
                if cells[i] != 0 and cells[i] not in ph:
                    issues.append("dangling phandle 0x%x in %s:%s" % (cells[i], n.pretty(), pname))
    labels = {}
    for n in root.walk():
        if n.label:
            if n.label in labels:
                issues.append("duplicate label %s" % n.label)
            labels[n.label] = n.pretty()
    return issues, len(ph), labels


# =========================================================================== #
# main
# =========================================================================== #
def build(compile_dtb=True):
    S, B = parse_file(SKELETON), parse_file(BOARD)
    m = Merger(S, B)
    out = m.run()
    lines = ["/dts-v1/;", "", ""]
    emit(out, 0, lines)
    txt = "\n".join(lines) + "\n"
    open(OUT_DTS, "w").write(txt)
    r = None
    if compile_dtb:
        r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-@", "-o", OUT_DTB, OUT_DTS],
                           capture_output=True, text=True)
    return m, out, r


def _find(root, path):
    n = root
    for seg in path.strip("/").split("/"):
        n = n.find(seg) if n else None
    return n


def _cells(root, path, prop):
    n = _find(root, path)
    if n is None or prop not in n.props:
        return None
    return n.props[prop].cells()


def _strs(root, path, prop):
    n = _find(root, path)
    if n is None or prop not in n.props:
        return None
    return n.props[prop].strings()


def assertions(root):
    """Return an ordered list of (name, ok, detail)."""
    res = []

    def add(name, ok, detail):
        res.append((name, bool(ok), detail))

    # gmac rgmii delays (must match the live board verbatim)
    add("gmac0(fe2a0000) tx/rx delay", _cells(root, "/ethernet@fe2a0000", "tx_delay") == [0x21]
        and _cells(root, "/ethernet@fe2a0000", "rx_delay") == [0x3c],
        "tx=%s rx=%s" % (_cells(root, "/ethernet@fe2a0000", "tx_delay"),
                         _cells(root, "/ethernet@fe2a0000", "rx_delay")))
    add("gmac1(fe010000) tx/rx delay", _cells(root, "/ethernet@fe010000", "tx_delay") == [0x2f]
        and _cells(root, "/ethernet@fe010000", "rx_delay") == [0x39],
        "tx=%s rx=%s" % (_cells(root, "/ethernet@fe010000", "tx_delay"),
                         _cells(root, "/ethernet@fe010000", "rx_delay")))
    # gmac mdio PHY + Maxio compatible
    for eth in ("/ethernet@fe2a0000", "/ethernet@fe010000"):
        n = _find(root, eth)
        mdio = n.find("mdio") if n else None
        phys = list(mdio.children.values()) if mdio else []
        ok = bool(phys) and any(any("maxio" in s for s in p.props["compatible"].strings())
                                for p in phys if "compatible" in p.props)
        detail = [(p.name, (p.props["compatible"].strings() if "compatible" in p.props else []),
                   p.props.get("reg").cells() if p.props.get("reg") else None) for p in phys]
        add("%s mdio Maxio PHY" % eth, ok, detail)
    # sata
    for p in ("/sata@fc000000", "/sata@fc400000", "/sata@fc800000"):
        add("%s status" % p, _strs(root, p, "status") == ["okay"], _strs(root, p, "status"))
    # usb glue + dwc3 child
    for glue, child in (("/usbdrd30", "/usbdrd30/dwc3@fcc00000"),
                        ("/usbhost30", "/usbhost30/dwc3@fd000000")):
        gn, cn = _find(root, glue), _find(root, child)
        add("%s + dwc3 child" % glue, gn is not None and cn is not None,
            "%s -> %s" % (gn.name if gn else None, cn.name if cn else None))
    for p in ("/usb@fd800000", "/usb@fd840000", "/usb@fd880000", "/usb@fd8c0000"):
        add("%s exists" % p, _find(root, p) is not None, _strs(root, p, "status"))
    # wifi sdio
    add("mmc@fe000000 (sdmmc2/WiFi) status", _strs(root, "/mmc@fe000000", "status") == ["okay"],
        _strs(root, "/mmc@fe000000", "status"))
    # pmic regulators
    for reg, label in (("DCDC_REG1", "vdd_logic"), ("DCDC_REG2", "vdd_gpu"),
                       ("DCDC_REG3", "vcc_ddr"), ("DCDC_REG4", "vdd_npu")):
        nm = _strs(root, "/i2c@fdd40000/pmic@20/regulators/" + reg, "regulator-name")
        add("PMIC %s" % reg, nm == [label], nm)
    add("PMIC has codec", _find(root, "/i2c@fdd40000/pmic@20/codec") is not None,
        _strs(root, "/i2c@fdd40000/pmic@20/codec", "compatible"))
    add("TCS4525 vdd_cpu", _strs(root, "/i2c@fdd40000/regulator@1c", "regulator-name") == ["vdd_cpu"],
        _strs(root, "/i2c@fdd40000/regulator@1c", "regulator-name"))
    # rtc / camera / sdio pwrseq / wireless
    add("hym8563 rtc @i2c5", _strs(root, "/i2c@fe5e0000/hym8563@51", "compatible") is not None,
        _strs(root, "/i2c@fe5e0000/hym8563@51", "compatible"))
    add("gc5035 camera @i2c4", _strs(root, "/i2c@fe5d0000/gc5035@37", "compatible") is not None,
        _strs(root, "/i2c@fe5d0000/gc5035@37", "compatible"))
    add("sdio-pwrseq present", _find(root, "/sdio-pwrseq") is not None, None)
    add("wireless-wlan present", _find(root, "/wireless-wlan") is not None, None)
    add("leds present", _find(root, "/leds") is not None, None)
    add("adc-keys vol-up", _find(root, "/adc-keys/vol-up-key") is not None,
        _strs(root, "/adc-keys/vol-up-key", "label"))
    # negatives: R5S-only nodes must be gone
    for p in ("/hdmi-con", "/gpio-leds", "/gpio-keys", "/regulator-vdd-usbc"):
        add("R5S-only %s removed" % p, _find(root, p) is None, None)
    # NPU / iommu preserved from skeleton (iron rule #5)
    npu = _cells(root, "/npu@fde40000", "clocks")
    iommu = _strs(root, "/iommu@fde4b000", "compatible")
    add("NPU node kept", _find(root, "/npu@fde40000") is not None, None)
    add("iommu@fde4b000 kept", iommu is not None, iommu)
    return res


if __name__ == "__main__":
    m, out, r = build()
    issues, nph, labels = validate(out)
    dts = open(OUT_DTS).read()
    print("== merge stats ==")
    for k, v in sorted(m.stats.items()):
        print("   %-16s %s" % (k, v))
    if m.missed:
        print("   missed:", m.missed)
    print("== tree ==")
    print("   top-level nodes:", len(out.children), " total nodes:", len(list(out.walk())))
    print("   phandles:", nph, " labels:", labels)
    print("== dtc ==")
    if r is not None:
        print("   errors=%d warnings=%d exit=%d" % (r.stderr.count("Error"), r.stderr.count("Warning"), r.returncode))
        if r.returncode != 0:
            print(r.stderr[:3000])
    print("== validation ==")
    print("   issues:", len(issues))
    for i in issues[:60]:
        print("   !", i)
    # round-trip
    rt = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", "/tmp/k1_roundtrip.dts", OUT_DTB],
                        capture_output=True, text=True)
    rtroot = parse_file("/tmp/k1_roundtrip.dts")
    print("== round-trip (dtb -> dts) ==")
    print("   errors=%d  nodes=%d  top=%d" % (rt.stderr.count("Error"),
                                              len(list(rtroot.walk())), len(rtroot.children)))
    print("== assertions (on the round-tripped DTB) ==")
    npass = 0
    for name, ok, detail in assertions(rtroot):
        npass += ok
        print("   [%s] %-38s %s" % ("PASS" if ok else "FAIL", name, "" if detail is None else detail))
    print("   passed %d/%d" % (npass, len(assertions(rtroot))))
    print("== assertions (DTS source labels) ==")
    for lab in ("vdd_logic: DCDC_REG1", "vdd_gpu: DCDC_REG2", "vcc_ddr: DCDC_REG3", "vdd_npu: DCDC_REG4"):
        print("   [%s] %s" % ("PASS" if lab in dts else "FAIL", lab))
    for f in (OUT_DTS, OUT_DTB):
        h = hashlib.sha256(open(f, "rb").read()).hexdigest()
        print("   %s  sha256=%s  bytes=%d" % (f, h, os.path.getsize(f)))

