# IVE XNN Dispatch: Registers and Task Nodes (Hi3516EV300)

How a CNN inference (the IVE built-in **XNN** engine, EV300 has no NNIE) is
driven, and where the authoritative decode lives. Companion to
[`ive-registers.md`](ive-registers.md) (a live DMA/SAD/CCL capture) and
[`xnn-ioctl-trace-spec.md`](xnn-ioctl-trace-spec.md) (the `/dev/ive` ioctl + OMS
model RE). Last updated: 2026-09-29.

## The engine is a DRAM task-node DMA engine, not an MMIO-parameter block

The authoritative reference is the clean-room GPL driver
**`openhisilicon/kernel/ive_neo/ive_neo.c`** (`OpenIPC/openhisilicon`), which
implements OMS load + XNN forward for the V4 fused IVE+NEO block at
`0x11320000` (ev200/ev300/gk7205v200/v300) and is cross-checked against the
vendor blob. It shows the operation parameters are **not** written to per-field
MMIO registers. Every op — a classic IVE op *or* one XNN layer — is a **208-byte
task-node descriptor in DRAM**; the XNN forward is a linked chain of them, one
node per Conv/FC/Flatten/Preproc layer, built from the OMS layer descriptors by
`ive_build_task_nodes()`. The MMIO surface the driver actually touches is tiny:

| Reg | Driver use (`ive_neo.c`) |
|-----|--------------------------|
| `+0x00` | **fire** — `writel(1)` starts the chain HW reads from `+0x10` |
| `+0x04` | int enable — `writel(6)` |
| `+0x08` | int clear/ack — `writel(7)` |
| `+0x0C` | status (read in the IRQ handler) |
| `+0x10` | **task-node chain physical address** (head node) |
| `+0x18` | task/completion counter (advances as nodes retire) |
| `+0x34` | clock gate enable (`|1`) — NEO/XNN |
| `+0x54` | outstanding-transaction config (`&~0xf|7`, then `|0xf00`) |
| `+0x60` | write-timeout (`0xffffffff`) |
| `+0x84`,`+0x88` | Conv-critical enables — `writel(1)` each (OSAL rmmod clears them) |
| `+0x8C` | MMZ base (`>>12`) |
| `+0x80`/`+0x90` | HW-ID / capability probe |

Each node's first word is the **next-node physical address** (`ive_link_node`,
last = 0), so HW walks the chain by DMA after a single `dsb`-fenced kick. This
supersedes, for how operations are configured, the `0x0104 OP_TYPE` /
`0x0108 DIMENSIONS` / `0x0110 SRC_ADDR` / `0x0128 STRIDES` interpretation in
`ive-registers.md` (that motion-detection capture read the `0x0100` window, but
the working driver never writes those offsets — the op is the DRAM node).

## Part B is already decoded — in `ive_neo`, not "to do"

An earlier draft of this doc listed the conv/fc parameter encoding as needing RE
of `hi3516ev200_ive.ko`. **That RE is done.** `ive_neo.c`'s
`ive_build_task_nodes()` carries the byte-level OMS-descriptor → task-node field
map, derived from IDA of the vendor `ive_xnn_parse_conv`
(`ive_xnn_parse_conv_constprop_40`). For a Conv layer:

- **OMS descriptor** (from `xnn-ioctl-trace-spec.md`): `desc[3]=in_fmt`,
  `[4]=out_fmt`, `[5]=pool_mode`, `[6]=af_mode`, `[7]=is_pad`, `[8:9]=in_c`,
  `[10:11]=in_h`, `[12:13]=in_w`, `[14:15]=out_c`, `[16:17]=out_h`,
  `[18:19]=out_w`, `[20:23]=arg_len`, `[24:27]=arg_off`, `[40:43]=in_tmp`,
  `[44:47]=out_tmp`, `[48:49]=in_stride`, `[50:51]=out_stride`,
  `[61]=kernel_size`, `[62]=in_bond_num`.
- **208-byte HW node** (offsets): `+8=in_fmt`, `+9=out_fmt`, `+10=0x36`,
  `+16/+20=in/out tmp phys`, `+24=weights phys`, `+28=arg_len`, `+40/+42=in_w/in_h`,
  `+44/+46=in/out stride`, `+48/+50=in_c/out_c`, `+52/+56=requant`,
  `+60=af_mode`, `+61=pool_mode`, `+62=in_fmt`, `+64/+68=requant`, `+73=kernel_size`,
  `+74/+75/+76/+77=rows/cols/tile_h/tile_w`, `+78=in_bond_num`, `+116=out bytes`.
- **Tiling** (`bond==1`→64×4; `in_w≤16`→16×16; else 32×8; `ksize==3` adjusts the
  row/col count) is computed in the driver, matching the IDA reference.

FC/Flatten/Preproc nodes are built the same way; **Eltwise/DMA-layer (type 6) is
not implemented** and such models are rejected at load. So the full parameter
configuration for an XNN forward is `ive_build_task_nodes()` — read it there
rather than trying to map fields onto `0x0100` MMIO.

## Blob input, and the empirical caveat

- Vendor **OMS** models are what the loader expects; `xnn-ioctl-trace-spec.md`
  and `oms_parser.py` decode them. XiongMai's Sofia `fd.bin`/`pd_8.bin` are an
  **XM-private, non-OMS** container (face path is SSH-family, per
  `FdSshGetTotalMemorySize`; `IVE_XNN_PREPROC_TYPE_CPU`, single scale), so they
  do not parse as OMS and their per-layer dims are not directly readable.
- **XNN HW completion is not yet observed on this SoC.** `ive_neo`'s forward
  notes that the vendor `+0x18` task counter never advances for the XNN chain
  (same for the vendor driver in the tested setup), so end-to-end XNN inference
  is not a confirmed-working, push-button path even though the descriptor build
  is complete. Track this in `ive_neo` before assuming a guest/host forward
  yields real detections.

## QEMU relevance

The QEMU `hisi-ive` regbank is still a stub. A functional XNN device would model
the task-node DMA path above: on `+0x00` fire, walk the chain from `+0x10`,
execute each node by its type/field map (the `ive_build_task_nodes` layout),
advance `+0x18`, and raise the IVE IRQ (SPI 51 on EV300; note `ive_abi_notes.md`
records IRQ 83 for ev200/gk7205v200 — confirm per machine). `ive_neo` built with
`-DIVE_STANDALONE` runs against such a device without vendor modules.
