# RK3588 camera streaming hangs: causes and fixes

Starting and stopping camera streams repeatedly could hang a ROCK 5B+ (IMX708 on
CAM0, VICAP capture through `rockchip-cif`, Ubuntu 7.3.0-9) with no kernel
message. This note lists every change that fixes or prevents those hangs, what
was tried that did not help, and what is still not understood.

**Status**

| # | Fix | State |
|---|---|---|
| 1 | rkcif stream-stop race | committed (`7e77b54`, `1790857`) |
| 2 | no CRU reset in runtime suspend, soft reset at stop | committed; reduces the hang a lot, but one hang was seen afterwards, see "A hang that remains" |
| 3 | IMX708 minimum idle link time between lines | committed (`ad16019`, `91fadfe`, `cd573bd`) |

## Symptoms

- The board freezes with nothing logged. SSH and the kernel log stream die.
  Some stalls end by themselves after minutes (2.5 and 8.8 minutes were seen);
  one had not recovered after 17 minutes and needed a power cycle. The last kernel line is usually `imx708 ...: configured
  N lanes`, i.e. the hang comes in the first moments of a stream, after an
  earlier stream was stopped.
- It is intermittent: after 1 to about 40 start/stop cycles, more often at high
  frame rates (binned 2304x1296 at about 170 fps, 720p at about 180 fps).
- It happens with plain `v4l2-ctl` and with libcamera, with `rockchip_isp2`
  unloaded, and at 549 and 750 MHz link frequency.
- A related failure: the CSI receive chain stops delivering frames
  (`v4l2-ctl` times out) until the sensor is rebound. See fix 3.

## Fix 1: rkcif stream-stop race (committed)

Ubuntu's `rockchip-cif` is Linux v7.3's rkcif, unchanged. Its
`rkcif_stream_stop_streaming()` stopped the sensor first, waited up to 1 s for a
frame end that the stopped sensor could not produce, then dropped runtime PM
and freed the buffers and the dummy buffer while the DMA could still be
writing. The frame-end interrupt handler also took the subdev state mutex.

The package now ships its own copy of the driver
([src/rkcif](../packages/rk3588-camera-dkms/src/rkcif), imported unchanged in
`7e77b54`) and DKMS installs it under `updates/dkms`, which depmod searches
before the in-tree module. The fix in `1790857`:

1. stop the capture at the next frame end, while the sensor is still sending;
2. stop the sensor;
3. return the buffers and free the dummy buffer, now that the DMA is idle;
4. drop the runtime PM reference.

If no frame end arrives within 1 s it stops mid-frame and warns. The interrupt
path calls a register-only stop helper under a new spinlock (`stop_lock`)
instead of taking the mutex.

Effect: raw `v4l2-ctl` capture went from hanging after 1 to 6 starts to 80 or
more clean starts. It did not remove all hangs (see fix 2).

## Fix 2: no CRU reset in runtime suspend, soft reset at stop (committed)

What was left after fix 1 was a silent hang at the start of a stream after an
earlier one had stopped. It comes from the hardware reset in
`rkcif_runtime_suspend()` ([rkcif-dev.c](../packages/rk3588-camera-dkms/src/rkcif/rkcif-dev.c)):
it pulses the CIF reset line (CRU reset: DMA, FIFOs, AXI interface, and the
IOMMU too) every time the device suspends, i.e. after every stream.

Rockchip's vendor driver (`armbian/linux-rockchip`, `rk-6.1-rkr5.1`,
`drivers/media/platform/rockchip/cif/capture.c`) does not do that on RK3588:
`rkcif_do_cru_reset()` has one caller, `rkcif_do_reset_work_below_rk3588()`,
the error-recovery path for older chips. On RK3588 its stop path calls
`rkcif_do_soft_reset()`, which sets `0x000A0000` in the MIPI interface control
register and waits 10 to 20 us.

The change that was tested:

- skip the CRU reset in `rkcif_runtime_suspend()` on RK3588;
- at stream stop, after the sensor has stopped and only if no other stream on
  that interface is still streaming, write `0x000A0000` (bits 19 and 17) to the
  interface's `RKCIF_MIPI_CTRL` register and wait 10 to 20 us
  (`rkcif_mipi_soft_reset()` in
  [rkcif-capture-mipi.c](../packages/rk3588-camera-dkms/src/rkcif/rkcif-capture-mipi.c)).

The soft reset is still needed. Without any reset between streams the DMA
keeps the previous stream's frame address. If the buffer layout then changes
(for example binned to full resolution) the first frame is written to an
unmapped IOVA and the IOMMU raises about 10 000 identical page faults. One such
storm stalled the CPUs for about 9 minutes before the board recovered by
itself. With the soft reset, 60 starts that changed layout every time had no
faults.

The tests used a loop that mimics libcamera's buffer handling on the rkcif
node: `REQBUFS(MMAP)`, `EXPBUF`, `REQBUFS(0)`, then queue the exported fds as
DMABUFs, 4 buffers, 120 frames per start. Same sensor setup throughout:
4 lanes at 750 MHz link frequency, `min_line_gap_ns=500`.

| CRU reset | Extra | Starts before the hang |
|---|---|---|
| on | none (stock) | 7, 38, about 14, 15 |
| on | soft reset at stop, before the CRU reset | 10 |
| on | soft reset after the CRU reset, in suspend | 14 |
| on | DMA idle bit first | 34 |
| on | DMA idle first, IOMMU re-initialised after | 11 |
| on | fix 1 only, libcamera runs 3 s apart | stalled on run 3 |
| on | fix 1 only, libcamera runs 10 s apart | stalled on run 7 |
| **off** | none | 260 clean |
| **off** | soft reset at stop | 120 same-layout clean, 60 layout-changing clean |

With the CRU reset off and the soft reset on, also clean:

- libcamera raw, 60 runs across full, binned and 720p (45 / 168 / 178 fps);
- 20 raw DMABUF captures each followed immediately by a libcamera run (this
  sequence hung about half the time before);
- 150 full-resolution starts, 140 starts that cycled full, binned, 720p and HDR,
  and 1800 to 6000 frame sustained streams in each mode, all at the sensor's
  computed frame rate.

With the CRU reset on, nothing added made a difference, whatever the order.
With it off, the hang that came every 7 to 38 starts did not recur in about 830
starts across the diagnostic builds. One hang was seen later on the committed
code, see "A hang that remains".

**How it is selected.** The tests above ran with module parameters that
turned each reset on or off. The committed code has no parameters: the match
data of an SoC sets `mipi_soft_reset` (RK3588 only), which skips the CRU
reset in `rkcif_runtime_suspend()` and does the soft reset at stop. Other SoCs
keep the CRU reset.

## Fix 3: IMX708 idle time between lines (committed)

At 4 lanes and 750 MHz a binned line took about 0.3 us longer to read out than
to send, leaving the CSI link idle for 0.31 us between lines. The second stream
start then delivered no frames, in any mode, until the sensor was rebound
(unbind and bind `3-001a`). With 0.51 us idle, 40 binned starts were clean.
Some earlier hangs at 0.5 and 0.6 us were rkcif's stop bug (fix 1) and looked
as if the gap mattered; they were not caused by it.

The imx708 driver now picks mode timings from the link and keeps
`min_line_gap_ns` (default 500) of idle link time per line, on top of an 8%
margin (`link_margin_pct`). See `6fa8405`, `ad16019`, `91fadfe`, `cd573bd`.

## A hang that remains

On the installed package built from the fix commit (CRU reset skipped, soft
reset at stop, no debugging code), a libcamera raw loop at full speed hung the
board silently on its 40th run. That was the 430th sensor start of that boot.
Nothing was logged: no page fault, stall or error, and the log ends after the
sensor started, as in every earlier hang.

The same boot had run these clean first: 150 same-layout starts, 140 starts
that changed mode every time, 60 libcamera runs (at a quarter of full speed
because `vertical_blanking` was stuck at 3673, see the pitfalls below), 20
raw-then-libcamera switches, and 39 libcamera runs at full speed.

With a 3 s pause between runs the committed build ran 60 libcamera runs clean.
A pause does not make the CRU reset safe: with it back on and no soft reset
(fix 1 only), runs 3 s apart stalled on run 3 and runs 10 s apart on run 7.
That is why fix 2 stays.

Two readings fit, and they have not been told apart:

- the hang is still there but rare: it went from one in 7 to 38 starts to
  perhaps one in a few hundred, and the earlier 830 clean starts were
  partly luck;
- the diagnostic builds had logging in the stop path (`stop_debug` and the
  DMABUF monitor, with extra delay between the source stopping and the soft
  reset), and removing it changed the timing of a race.

## Did not help

- Setting the DMA idle bit before the CRU reset, or re-enabling the IOMMU
  after it (the vendor's older-chip sequence).
- Doing the soft reset before or after the CRU reset.
- Pinning `rockchip-cif` and its IOMMU on (`power/control=on`). It avoids the
  hang (no reset runs) but causes the stale-address page-fault storm above.
- More line gap (0.6 us) or more link margin (15%).

## Not understood

Why the CRU reset pulse hangs the board is not known. The evidence is
correlation across several hundred runs. A reset of the AXI interface with
traffic in flight is a candidate; it was not shown.

## Testing pitfalls

- `vertical_blanking` keeps its value across mode changes and across toggling
  `wide_dynamic_range`. Switching HDR off left it at 3673, and every later raw
  run streamed at 46 fps (binned) and 36 fps (720p). Set it to the control's
  `min=` before each run, and compare the measured frame rate to the computed
  one.
- rkcif's buffer `sequence` only increments for real buffers. Frames written to
  the dummy buffer because userspace was too slow are not visible as sequence
  gaps. A "dropped 0" count does not rule them out; a frame rate below the
  sensor's computed rate does.
- Do not pin runtime PM when testing the unpinned behaviour.
- Processed (ISP) streams above 2304x1296 are rejected by libcamera for an
  unrelated reason, see
  [rkisp2-4416x3312-output-limit.md](rkisp2-4416x3312-output-limit.md). Raw
  streams are not affected, so these tests use raw only.
