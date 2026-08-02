#!/usr/bin/env python3
"""
Build-time rule processing. Runs in the Docker build, never on the router.

Why this exists: mosdns holds every rule entry in RAM on a 1 GB RB5009.
Anything that can be decided at build time should be, so the router only
loads entries that can actually change a routing decision.

Outputs into <outdir>:
  geosite_cn.txt      merged direct-list + apple-cn, deduped, suffix-collapsed
  geosite_proxy.txt   proxy-list reduced to entries that can override a CN
                      match (see below) - this is what the default config loads
  geosite_proxy_full.txt  the complete proxy-list, for cn-first mode
  geoip_cn.txt        CN IP ranges, only needed in cn-first mode

The proxy reduction: in the default sequence the last branch already sends
everything unmatched to the remote upstreams. So a proxy-list entry only
changes an outcome when it overlaps the CN set - otherwise the query lands
remote either way. Keeping only the overlap cuts ~27k entries to ~460 with
byte-identical routing behaviour. If you switch the default branch to
seq_default_cn_first, that assumption breaks: use the _full file instead.
"""
import sys, os, urllib.request

SRC = {
    "direct":  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt",
    "apple":   "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt",
    "proxy":   "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt",
    "geoip":   "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/cn.txt",
}
PREFIXES = ("full:", "regexp:", "keyword:", "domain:")


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


def parse(text):
    out = []
    for ln in text.splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            out.append(ln)
    return out


def split_prefix(e):
    for p in PREFIXES:
        if e.startswith(p):
            return p, e[len(p):]
    return "", e


def collapse(entries):
    """Drop entries already covered by a broader suffix rule in the same set."""
    suffix, other = set(), []
    for e in entries:
        p, d = split_prefix(e)
        (suffix.add(d) if p in ("", "domain:") else other.append(e))

    def covered(d):
        parts = d.split(".")
        return any(".".join(parts[i:]) in suffix for i in range(1, len(parts)))

    kept_suffix = sorted({d for d in suffix if not covered(d)})
    kept_other = sorted({e for e in other
                         if not (split_prefix(e)[0] == "full:"
                                 and (split_prefix(e)[1] in suffix
                                      or covered(split_prefix(e)[1])))})
    return kept_suffix, kept_other


def reduce_proxy(proxy, cn_suffixes):
    """Keep only proxy entries that can override a CN match."""
    index = {}
    for c in cn_suffixes:
        index.setdefault(c.split(".")[-2] if c.count(".") else c, []).append(c)
    keep = []
    for e in proxy:
        p, d = split_prefix(e)
        if p in ("regexp:", "keyword:"):
            keep.append(e); continue
        if d in cn_suffixes:
            keep.append(e); continue
        parts = d.split(".")
        if any(".".join(parts[i:]) in cn_suffixes for i in range(1, len(parts))):
            keep.append(e); continue
        key = d.split(".")[-2] if d.count(".") else d
        if any(c.endswith("." + d) for c in index.get(key, [])):
            keep.append(e)
    return keep


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    raw = {k: parse(fetch(u)) for k, u in SRC.items()}

    cn_raw = raw["direct"] + raw["apple"]
    cn_suf, cn_oth = collapse(cn_raw)
    cn_out = cn_suf + cn_oth
    cn_set = set(cn_suf) | {split_prefix(e)[1] for e in cn_oth
                            if split_prefix(e)[0] == "full:"}

    px_suf, px_oth = collapse(raw["proxy"])
    px_full = px_suf + px_oth
    px_min = reduce_proxy(px_full, cn_set)

    def write(name, lines):
        with open(os.path.join(outdir, name), "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"  {name:<24} {len(lines):>7} entries")

    print("rule build:")
    write("geosite_cn.txt", cn_out)
    write("geosite_proxy.txt", px_min)
    write("geosite_proxy_full.txt", px_full)
    write("geoip_cn.txt", raw["geoip"])
    print(f"  CN    {len(cn_raw)} -> {len(cn_out)}")
    print(f"  PROXY {len(raw['proxy'])} -> {len(px_min)} "
          f"(full kept separately for cn-first mode)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/out/rules")
