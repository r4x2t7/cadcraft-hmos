// HoCAD HarmonyOS shell (2in1 / PC + tablet): thin ArkUI front end over the Rust engine.
// Panels read engine state (cadState) and act through Cad* calls — the same discipline as
// the egui UI crate ("the UI is thin"). Canvas frames come from the CPU rasteriser, like
// the web and plot paths, displayed through an Image(pixelMap) component.
//
// All pointer coordinates handed to Cad are DEVICE pixels (vp × densityPixels).
//
// Display notes (empirical, this emulator image):
// - image.createPixelMap's promise can stall under host memory pressure → one pixelMap is
//   created per canvas size and refreshed with writePixels (no repeated large allocs).
// - Canvas putImageData maps ImageData rows at 1/dpr vertically on this image (colour-band
//   probe) → do not blit through Canvas. Image+objectFit(Fill) is 1:1 device pixels.
// - Recording Canvas path commands leaks native memory (AceCanvas never resets them) → the
//   grid is stamped into the frame pixels and the overlay canvas redraws only on rare
//   events, never per frame.

import { Cad, CadState, CadView, CadLayer, CadSel, CadMenu, CadMenuItem, CadGrip } from '../bridge/CadBridge';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import displaySync from '@ohos.graphics.displaySync';
import print from '@ohos.print';
import { uniformTypeDescriptor } from '@kit.ArkData';
import unifiedDataChannel from '@ohos.data.unifiedDataChannel';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

const BG: string = '#212830';
const PANEL: string = '#2a323c';
const PANEL_HI: string = '#333c48';
const ACCENT: string = '#14a3c7';
const TEXT: string = '#dfe6ee';
const DIM: string = '#9fb0c0';
const ACTIVE_MS: number = 1500; // pointer/key recency that keeps the render loop at 60fps

class MiddleDrag {
  down: boolean = false;
  lastX: number = 0;
  lastY: number = 0;
}

interface ToolDef {
  id: string;
  label: string;
  desc: string;
  icon?: Resource;
}

const TOP_ICONS: ToolDef[] = [
  { id: 'open', label: '打开', desc: '打开 DXF 图纸', icon: $r('app.media.icon_open') },
  { id: 'save', label: '保存', desc: '保存当前图为 DXF', icon: $r('app.media.icon_save') },
  { id: 'print', label: '打印', desc: '打印当前视图', icon: $r('app.media.icon_print') },
  { id: 'undo', label: 'UNDO', desc: '撤销上一步', icon: $r('app.media.icon_undo') },
  { id: 'redo', label: 'REDO', desc: '重做', icon: $r('app.media.icon_redo') },
  { id: 'zoomextents', label: '缩放范围', desc: '缩放到图纸全范围', icon: $r('app.media.icon_zoomextents') },
];

interface ToolGroup {
  name: string;
  large: ToolDef[];
  small: ToolDef[];
}

const TOOL_GROUPS: ToolGroup[] = [
  { name: '绘图', large: [
      { id: 'line', label: 'LINE', desc: '画直线', icon: $r('app.media.icon_line') },
      { id: 'circle', label: 'CIRCLE', desc: '画圆', icon: $r('app.media.icon_circle') },
    ], small: [
      { id: 'polyline', label: 'PLINE', desc: '多段线' },
      { id: 'rectang', label: 'RECT', desc: '矩形' },
      { id: 'arc', label: 'ARC', desc: '画弧', icon: $r('app.media.icon_arc') },
      { id: 'spline', label: 'SPLINE', desc: '样条曲线' },
      { id: 'ellipse', label: 'ELLIPSE', desc: '椭圆' },
      { id: 'polygon', label: 'POLYGON', desc: '多边形' },
      { id: 'xline', label: 'XLINE', desc: '构造线' },
      { id: 'ray', label: 'RAY', desc: '射线' },
      { id: 'point.multiple', label: 'POINT', desc: '多点' },
      { id: 'donut', label: 'DONUT', desc: '圆环' },
      { id: 'revcloud', label: 'CLOUD', desc: '云线' },
    ],
  },
  { name: '填充', large: [
      { id: 'hatch', label: 'HATCH', desc: '填充', icon: $r('app.media.icon_hatch') },
    ], small: [
      { id: 'gradient', label: 'GRADIENT', desc: '渐变填充' },
      { id: 'boundary', label: 'BOUNDARY', desc: '边界' },
    ],
  },
  { name: '修改', large: [
      { id: 'move', label: 'MOVE', desc: '移动', icon: $r('app.media.icon_move') },
    ], small: [
      { id: 'erase', label: 'ERASE', desc: '删除', icon: $r('app.media.icon_erase') },
      { id: 'copy', label: 'COPY', desc: '复制', icon: $r('app.media.icon_copy') },
      { id: 'rotate', label: 'ROTATE', desc: '旋转' },
      { id: 'scale', label: 'SCALE', desc: '缩放' },
      { id: 'mirror', label: 'MIRROR', desc: '镜像' },
      { id: 'offset', label: 'OFFSET', desc: '偏移', icon: $r('app.media.icon_offset') },
      { id: 'trim', label: 'TRIM', desc: '修剪', icon: $r('app.media.icon_trim') },
      { id: 'extend', label: 'EXTEND', desc: '延伸' },
      { id: 'fillet', label: 'FILLET', desc: '圆角' },
      { id: 'chamfer', label: 'CHAMFER', desc: '倒角' },
      { id: 'arrayrect', label: 'ARRAY', desc: '矩形阵列' },
      { id: 'arraypolar', label: 'ARRAYP', desc: '环形阵列' },
      { id: 'stretch', label: 'STRETCH', desc: '拉伸' },
      { id: 'explode', label: 'EXPLODE', desc: '分解' },
      { id: 'break', label: 'BREAK', desc: '打断' },
      { id: 'join', label: 'JOIN', desc: '合并' },
      { id: 'lengthen', label: 'LENGTHEN', desc: '拉长' },
      { id: 'matchprop', label: 'MATCHPROP', desc: '特性匹配' },
    ],
  },
  { name: '标注', large: [
      { id: 'dimlinear', label: 'DIM', desc: '线性标注', icon: $r('app.media.icon_dimlinear') },
    ], small: [
      { id: 'dimaligned', label: 'DIMALI', desc: '对齐标注' },
      { id: 'dimradius', label: 'DIMRAD', desc: '半径标注' },
      { id: 'dimdiameter', label: 'DIMDIA', desc: '直径标注' },
      { id: 'dimangular', label: 'DIMANG', desc: '角度标注' },
      { id: 'qdim', label: 'QDIM', desc: '快速标注' },
    ],
  },
  { name: '文字', large: [
      { id: 'mtext', label: 'MTEXT', desc: '多行文字', icon: $r('app.media.icon_mtext') },
    ], small: [
      { id: 'text', label: 'TEXT', desc: '单行文字' },
    ],
  },
];


@Entry
@Component
struct Index {
  @State prompt: string = '';
  @State keywords: string[] = [];
  @State log: string[] = [];
  @State status: string = '';
  @State toast: string = '';
  private toastAt: number = 0;
  @State cmdText: string = '';
  @State canvasFocused: boolean = false;
  @State lastPinch: number = 1;
  @State frameMs: string = '';
  @State menus: CadMenu[] = [];
  @State layers: CadLayer[] = [];
  @State currentLayer: string = '';
  @State selection: CadSel[] = [];
  @State coordsText: string = '';
  private crossX: number = -100;
  private crossY: number = -100;
  @State gridOn: boolean = true;
  @State openMenu: number = -1;
  @State menuX: number = 0;
  @State spaceName: string = '模型';
  @State layouts: string[] = [];
  @State docs: string[] = [];
  @State docIdx: number = 0;
  @State ortho: boolean = false;
  @State osnap: boolean = false;
  @State windowFrom: number[] | null = null;
  @State grips: CadGrip[] = [];
  @State hotGrip: CadGrip | null = null;
  @State suggestions: string[] = [];
  @State layerNewOpen: boolean = false;
  @State newLayerName: string = '';
  @State ctxLayer: string = '';
  @State ctxOpen: boolean = false;
  @State collapsedGroups: string[] = [];
  @State geomValue: string = '';
  @State hatchOpen: boolean = false;
  @State hatchPattern: string = 'ANSI31';
  @State hatchScale: string = '1';
  @State hatchAngle: string = '0';
  @State mtextOpen: boolean = false;
  @State mtextText: string = '';
  @State mtextHeight: string = '2.5';
  @State pendingPlace: string = '';
  @State zoomWinMode: boolean = false;
  @State zoomWinFirst: number[] | null = null;
  @State snapMark: number[] | null = null; // '' | 'hatch' | 'mtext'
  @State tipText: string = '';
  private tipTimer: number = -1;
  @State pmVersion: number = 0; // bumps when a new pixelMap is installed (Image refresh)
  private allIds: string[] = [];
  private overlaySettings: RenderingContextSettings = new RenderingContextSettings(true);
  private ovlCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.overlaySettings);
  private histScroller: Scroller = new Scroller();
  @State pixelMap: image.PixelMap | null = null;
  private lastBuf: ArrayBuffer = new ArrayBuffer(0);
  private frameBuf: ArrayBuffer = new ArrayBuffer(0);
  // Fit the view once the real canvas size is known (DXF load happens before layout).
  private needFit: boolean = false;
  private dpr: number = 1;
  private canvasW: number = 0; // vp
  private canvasH: number = 0; // vp
  private middle: MiddleDrag = new MiddleDrag();
  private ctrlHeld: boolean = false;
  private dirty: boolean = true;
  private frames: number = 0;
  private lastActive: number = 0;
  private rateHigh: boolean = false;
  private panAccX: number = 0;
  private panAccY: number = 0;
  // World view of the last cadState (for the coordinate readout).
  private viewCenterX: number = 0;
  private viewCenterY: number = 0;
  private viewHeightW: number = 0;
  // DisplaySync-driven render loop: VSync-aligned when the image fires frames, with a
  // liveness-checked 100ms interval fallback (some emulator images never fire frames).
  private renderer: displaySync.DisplaySync | null = null;
  private lastTickAt: number = 0;
  private fallbackTimer: number = -1;

  aboutToAppear(): void {
    this.dpr = display.getDefaultDisplaySync().densityPixels;
    this.menus = Cad.menus();
    // Flat command ids for the command-line autocomplete.
    for (const m of this.menus) {
      for (const it of m.items) {
        this.allIds.push(it.id);
      }
    }
    const state: CadState = Cad.init();
    this.applyState(state);
    this.renderer = displaySync.create();
    this.renderer.on('frame', () => this.tick());
    this.renderer.setExpectedFrameRateRange({ min: 5, max: 120, expected: 60 });
    this.lastTickAt = Date.now();
    this.fallbackTimer = setInterval(() => {
      if (Date.now() - this.lastTickAt >= 200) {
        this.tick();
      }
    }, 100);
    this.loadBenchmarkDrawing();
  }

  aboutToDisappear(): void {
    this.renderer?.off('frame');
    if (this.fallbackTimer >= 0) {
      clearInterval(this.fallbackTimer);
    }
  }

  tick(): void {
    this.lastTickAt = Date.now();
    this.frames += 1;
    const active: boolean =
      Date.now() - this.lastActive < ACTIVE_MS || this.middle.down || this.prompt.length > 0;
    if (active !== this.rateHigh) {
      this.rateHigh = active;
      this.renderer?.setExpectedFrameRateRange({ min: 5, max: 120, expected: active ? 60 : 5 });
    }
    if (this.dirty) {
      this.dirty = false;
      this.drawFrame();
    }
    if (this.frames % 30 === 0) {
      this.applyState(Cad.state());
    }
  }

  markActive(): void {
    this.lastActive = Date.now();
  }

  /** 瞬态消息：3 秒自动消失，不被 poll 覆盖。 */
  showToast(msg: string): void {
    this.toast = msg;
    this.toastAt = Date.now();
    setTimeout(() => {
      if (Date.now() - this.toastAt >= 2800) {
        this.toast = '';
      }
    }, 3000);
  }

  /** 工具 tooltip：长按图标显示说明，2.5s 自动消失。 */
  showTip(text: string): void {
    this.tipText = text;
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
    }
    this.tipTimer = setTimeout(() => {
      this.tipText = '';
    }, 2500);
  }

  applyState(state: CadState): void {
    if (!state.ok && state.error && Date.now() - this.toastAt >= 2000) {
      this.showToast(`错误: ${state.error}`);
    }
    this.prompt = state.prompt ? state.prompt.message : '';
    this.keywords = state.prompt ? state.prompt.keywords : [];
    if (state.log.length > 0) {
      this.log = state.log.slice(-12);
      this.histScroller.scrollEdge(Edge.Bottom);
    }
    this.layers = state.layers;
    this.currentLayer = state.currentLayer;
    this.selection = state.selection;
    this.spaceName = state.space;
    this.layouts = state.layouts;
    this.docs = state.docs;
    this.docIdx = state.doc;
    this.ortho = state.ortho;
    this.osnap = state.osnap;
    this.windowFrom = state.window;
    this.snapMark = state.snapMarker ?? null;
    this.grips = state.grips;
    if (state.frameMs !== undefined && state.frameMs > 0) {
      const vis: string = (state.visible !== undefined && state.total !== undefined && state.visible < state.total)
        ? ` ${state.visible}/${state.total}`
        : '';
      this.frameMs = `渲染 ${state.frameMs.toFixed(0)}ms (建 ${state.buildMs?.toFixed(0) ?? '?'} + 画 ${state.rasterMs?.toFixed(0) ?? '?'}${vis})`;
    }
    const view: CadView = state.view;
    this.viewCenterX = view.center[0];
    this.viewCenterY = view.center[1];
    this.viewHeightW = view.height;
    this.status = `视图高 ${view.height.toFixed(2)} | ${this.frameMs}`;
    this.drawCrosshair();
  }

  // ---------------- canvas ----------------

  /** Called from the overlay canvas area change / ready with the real vp size. */
  onCanvasSize(wVp: number, hVp: number): void {
    if (Math.round(wVp) === Math.round(this.canvasW) && Math.round(hVp) === Math.round(this.canvasH)) {
      return;
    }
    this.canvasW = wVp;
    this.canvasH = hVp;
    hilog.info(0x0000, 'cadcraft', 'canvas size %{public}dx%{public}d vp', Math.round(wVp), Math.round(hVp));
    Cad.resize(Math.round(wVp * this.dpr), Math.round(hVp * this.dpr));
    if (this.needFit) {
      this.needFit = false;
      this.applyState(Cad.zoomExtents());
    }
    this.dirty = true;
    this.drawCrosshair();
  }

  async drawFrame(): Promise<void> {
    const w: number = Math.round(this.canvasW * this.dpr);
    const h: number = Math.round(this.canvasH * this.dpr);
    if (w < 16 || h < 16) {
      hilog.warn(0x0000, 'cadcraft', 'drawFrame skip %{public}dx%{public}d', w, h);
      return;
    }
    Cad.resize(w, h);
    // One reusable frame buffer per canvas size — zero per-frame allocation (large allocs
    // stall the JS thread on a memory-starved host).
    if (this.frameBuf.byteLength !== w * h * 4) {
      this.frameBuf = new ArrayBuffer(w * h * 4);
    }
    const n: number = Cad.frameInto(this.frameBuf);
    if (n === 0) {
      hilog.warn(0x0000, 'cadcraft', 'Cad.frameInto empty at %{public}dx%{public}d', w, h);
      this.dirty = this.frames < 600; // retry: first frames race the async DXF load
      return;
    }
    const px: Uint8Array = new Uint8Array(this.frameBuf, 0, n);
    if (this.gridOn) {
      this.stampGridPixels(px, w, h);
    }
    try {
      // Display via an Image(pixelMap) component. createPixelMap reads the source buffer
      // as BGRA on this image (explicit srcPixelFormat is ignored), while the engine
      // emits RGBA — swap R/B in place once, then hand over.
      for (let i = 0; i + 3 < n; i += 4) {
        const r = px[i];
        px[i] = px[i + 2];
        px[i + 2] = r;
      }
      if (this.pixelMap === null || this.pixelMap.getImageInfoSync().size.width !== w
        || this.pixelMap.getImageInfoSync().size.height !== h) {
        if (this.pixelMap !== null) {
          await this.pixelMap.release();
        }
        const size: image.Size = { width: w, height: h };
        const opts: image.InitializationOptions = {
          size: size,
          srcPixelFormat: image.PixelMapFormat.BGRA_8888
        };
        this.pixelMap = await image.createPixelMap(this.frameBuf.slice(0, n), opts);
        this.pmVersion += 1;
      } else {
        const region: image.Region = { size: { width: w, height: h }, x: 0, y: 0 };
        const area: image.PositionArea = { pixels: this.frameBuf.slice(0, n), offset: 0, stride: w * 4, region: region };
        await this.pixelMap.writePixels(area);
      }
    } catch (e) {
      hilog.error(0x0000, 'cadcraft', 'drawFrame catch: %{public}s', `${e}`);
      this.showToast(`渲染: ${e}`);
    }
  }

  /**
   * Stamp the 1-2-5 world grid straight into the RGBA frame pixels. Recording Canvas path
   * commands leaks native memory on this image (AceCanvas never resets them — RSS grew to
   * 2.8 GB and the main thread blocked inside CanvasPattern::MoveTo -> malloc), so the
   * frame stays exactly one buffer fill + one putPixels per repaint.
   */
  stampGridPixels(px: Uint8Array, w: number, h: number): void {
    if (!(this.viewHeightW > 0) || w <= 0) {
      return;
    }
    const scale: number = h / this.viewHeightW; // device px per world unit
    const raw: number = this.viewHeightW / 10;
    const p: number = Math.pow(10, Math.floor(Math.log10(raw)));
    const r: number = raw / p;
    const step: number = (r < 1.5 ? 1 : r < 3.5 ? 2 : r < 7.5 ? 5 : 10) * p;
    if (!(step > 0) || step > 1e30) {
      return;
    }
    const worldLeft: number = this.viewCenterX - w / 2 / scale;
    const worldTop: number = this.viewCenterY + h / 2 / scale;
    let wx: number = Math.ceil(worldLeft / step) * step;
    let guard: number = 0;
    while ((wx - worldLeft) * scale <= w && guard < 512) {
      const sx: number = Math.round((wx - worldLeft) * scale);
      if (sx >= 0 && sx < w) {
        for (let y: number = 0; y < h; y++) {
          const i: number = (y * w + sx) * 4;
          px[i] = Math.min(255, px[i] + 20);
          px[i + 1] = Math.min(255, px[i + 1] + 20);
          px[i + 2] = Math.min(255, px[i + 2] + 20);
          px[i + 3] = 255;
        }
      }
      wx += step;
      guard++;
    }
    let wy: number = Math.ceil((worldTop - h / scale) / step) * step;
    guard = 0;
    while ((worldTop - wy) * scale <= h && guard < 512) {
      const sy: number = Math.round((worldTop - wy) * scale);
      if (sy >= 0 && sy < h) {
        for (let x: number = 0; x < w; x++) {
          const i: number = (sy * w + x) * 4;
          px[i] = Math.min(255, px[i] + 20);
          px[i + 1] = Math.min(255, px[i + 1] + 20);
          px[i + 2] = Math.min(255, px[i + 2] + 20);
          px[i + 3] = 255;
        }
      }
      wy += step;
      guard++;
    }
  }

  /** Crosshair overlay: vector lines on the transparent second canvas (cheap, rare). */
  drawCrosshair(): void {
    this.ovlCtx.clearRect(0, 0, this.canvasW, this.canvasH);
    // 选择窗口：引擎 pending_window 起点到光标的虚线框。
    if (this.windowFrom !== null && this.windowFrom.length === 2 && this.viewHeightW > 0
      && this.crossX >= 0) {
      const scale: number = this.canvasW / this.viewHeightW;
      const fx: number = (this.windowFrom[0] - this.viewCenterX) * scale + this.canvasW / 2;
      const fy: number = this.canvasH / 2 - (this.windowFrom[1] - this.viewCenterY) * scale;
      this.ovlCtx.setLineDash([6, 4]);
      this.ovlCtx.strokeStyle = 'rgba(20,163,199,0.8)';
      this.ovlCtx.lineWidth = 1;
      this.ovlCtx.strokeRect(Math.min(fx, this.crossX), Math.min(fy, this.crossY),
        Math.abs(this.crossX - fx), Math.abs(this.crossY - fy));
      this.ovlCtx.setLineDash([]);
    }
    // UCS 图标（右下角）：红 X / 绿 Y，桌面同款方位提示。
    const ux: number = this.canvasW - 30;
    const uy: number = this.canvasH - 16;
    this.ovlCtx.lineWidth = 2;
    this.ovlCtx.strokeStyle = 'rgba(224,80,80,0.9)';
    this.ovlCtx.beginPath();
    this.ovlCtx.moveTo(ux, uy);
    this.ovlCtx.lineTo(ux + 14, uy);
    this.ovlCtx.stroke();
    this.ovlCtx.strokeStyle = 'rgba(90,200,110,0.9)';
    this.ovlCtx.beginPath();
    this.ovlCtx.moveTo(ux, uy);
    this.ovlCtx.lineTo(ux, uy - 14);
    this.ovlCtx.stroke();
    this.ovlCtx.lineWidth = 1;
    // 捕捉标记
    if (this.snapMark !== null && this.snapMark.length >= 2 && this.viewHeightW > 0) {
      const scale: number = this.canvasW / this.viewHeightW;
      const mx: number = (this.snapMark[0] - this.viewCenterX) * scale + this.canvasW / 2;
      const my: number = this.canvasH / 2 - (this.snapMark[1] - this.viewCenterY) * scale;
      this.ovlCtx.strokeStyle = 'rgba(0,255,255,0.9)';
      this.ovlCtx.lineWidth = 2;
      this.ovlCtx.strokeRect(mx - 5, my - 5, 10, 10);
    }
    // 缩放窗口虚线
    if (this.zoomWinMode && this.zoomWinFirst !== null && this.viewHeightW > 0) {
      const scale: number = this.canvasW / this.viewHeightW;
      const fx: number = (this.zoomWinFirst[0] - this.viewCenterX) * scale + this.canvasW / 2;
      const fy: number = this.canvasH / 2 - (this.zoomWinFirst[1] - this.viewCenterY) * scale;
      this.ovlCtx.setLineDash([4, 3]);
      this.ovlCtx.strokeStyle = 'rgba(255,255,255,0.5)';
      this.ovlCtx.lineWidth = 1;
      this.ovlCtx.strokeRect(Math.min(fx, this.crossX), Math.min(fy, this.crossY),
        Math.abs(this.crossX - fx), Math.abs(this.crossY - fy));
      this.ovlCtx.setLineDash([]);
    }
    if (this.crossX < 0 || this.crossY < 0) {
      return;
    }
    this.ovlCtx.strokeStyle = 'rgba(223,230,238,0.75)';
    this.ovlCtx.beginPath();
    this.ovlCtx.moveTo(0, this.crossY);
    this.ovlCtx.lineTo(this.canvasW, this.crossY);
    this.ovlCtx.moveTo(this.crossX, 0);
    this.ovlCtx.lineTo(this.crossX, this.canvasH);
    this.ovlCtx.stroke();
    this.ovlCtx.strokeRect(this.crossX - 6, this.crossY - 6, 12, 12);
  }

  device(xVp: number, yVp: number): number[] {
    return [xVp * this.dpr, yVp * this.dpr];
  }

  /** World coordinates of a canvas vp point, for the status bar readout. */
  worldText(xVp: number, yVp: number): string {
    if (!(this.viewHeightW > 0) || this.canvasW <= 0) {
      return '';
    }
    const scale: number = this.canvasW / this.viewHeightW;
    const wx: number = this.viewCenterX + (xVp - this.canvasW / 2) / scale;
    const wy: number = this.viewCenterY - (yVp - this.canvasH / 2) / scale;
    return `${wx.toFixed(2)}, ${wy.toFixed(2)}`;
  }

  // ---------------- interactions ----------------

  handleMouse(event: MouseEvent): void {
    this.markActive();
    const p: number[] = this.device(event.x, event.y);
    this.crossX = event.x;
    this.crossY = event.y;
    this.coordsText = this.worldText(event.x, event.y);
    if (event.action === MouseAction.Move) {
      Cad.move(p[0], p[1]);
      if (this.middle.down) {
        const dx: number = p[0] - this.middle.lastX;
        const dy: number = p[1] - this.middle.lastY;
        this.middle.lastX = p[0];
        this.middle.lastY = p[1];
        this.panAccX += dx;
        this.panAccY += dy;
        Cad.pan(dx, dy);
        this.dirty = this.frames % 3 === 0;
      }
      // 十字光标 overlay 每次 Move 重画（clearRect + 2 线 + 1 框，矢量不积累指令）。
      // Hover 命令提示时重渲橡皮筋；空闲 hover 不重渲主画布（防 vsync Move 风暴 ANR）。
      this.drawCrosshair();
      this.dirty = this.dirty || this.prompt.length > 0;
      return;
    }
    if (event.action === MouseAction.Press) {
      this.drawCrosshair();
      if (event.button === MouseButton.Middle) {
        this.middle.down = true;
        this.middle.lastX = p[0];
        this.middle.lastY = p[1];
      } else if (event.button === MouseButton.Left) {
        if (this.zoomWinMode) {
          const scale: number = this.canvasW / this.viewHeightW;
          const wx: number = this.viewCenterX + (event.x - this.canvasW / 2) / scale;
          const wy: number = this.viewCenterY - (event.y - this.canvasH / 2) / scale;
          if (this.zoomWinFirst === null) {
            this.zoomWinFirst = [wx, wy];
          } else {
            const p: Record<string, number> = {
              'x1': this.zoomWinFirst[0], 'y1': this.zoomWinFirst[1],
              'x2': wx, 'y2': wy
            };
            this.applyState(Cad.execute('zoom_window', p));
            this.zoomWinMode = false;
            this.zoomWinFirst = null;
          }
          this.dirty = true;
          return;
        }
        if (this.pendingPlace !== '') {
          // 对话框确认后：这次点击是放置点（世界坐标）。
          const scale: number = this.canvasW / this.viewHeightW;
          const wx: number = this.viewCenterX + (event.x - this.canvasW / 2) / scale;
          const wy: number = this.viewCenterY - (event.y - this.canvasH / 2) / scale;
          if (this.pendingPlace === 'hatch') {
            const hs = Number(this.hatchScale) || 1;
            const an = Number(this.hatchAngle) || 0;
            const p: Record<string, string | number | number[][]> = {
              'points': [[wx, wy]], 'pattern': this.hatchPattern,
              'scale': hs, 'angle': an
            };
            this.applyState(Cad.execute('hatch', p));
          } else if (this.pendingPlace === 'mtext') {
            const hh = Number(this.mtextHeight) || 2.5;
            const p: Record<string, string | number | number[]> = {
              'at': [wx, wy], 'text': this.mtextText, 'height': hh
            };
            this.applyState(Cad.execute('mtext', p));
          }
          this.pendingPlace = '';
          this.dirty = true;
          return;
        }
        // 夹点流：空闲点击命中夹点 → 交互 GRIP（橡皮筋跟手，点击确认，Space 翻模式）。
        if (this.hotGrip === null) {
          const g = this.gripAt(event.x, event.y);
          if (g !== null) {
            this.hotGrip = g;
            this.applyState(Cad.gripEdit([[g.handle, g.index]]));
            this.markActive();
            this.dirty = true;
            return;
          }
        }
        this.applyState(Cad.click(p[0], p[1], false, this.ctrlHeld));
        this.dirty = true;
      }
      return;
    }
    if (event.action === MouseAction.Release && event.button === MouseButton.Middle) {
      this.middle.down = false;
      this.dirty = true;
    }
  }

  handleTouch(event: TouchEvent): void {
    this.markActive();
    if (event.type === TouchType.Up && event.changedTouches.length >= 1) {
      const t: TouchObject = event.changedTouches[0];
      const p: number[] = this.device(t.x, t.y);
      if (event.touches.length < 2) {
        this.applyState(Cad.click(p[0], p[1], false, false));
        this.dirty = true;
      }
      this.middle.down = false;
    } else if (event.type === TouchType.Move && event.touches.length === 2) {
      const a: TouchObject = event.touches[0];
      const b: TouchObject = event.touches[1];
      const cx: number[] = this.device((a.x + b.x) / 2, (a.y + b.y) / 2);
      if (this.middle.down) {
        Cad.pan(cx[0] - this.middle.lastX, cx[1] - this.middle.lastY);
        this.dirty = this.frames % 4 === 0;
      }
      this.middle.down = true;
      this.middle.lastX = cx[0];
      this.middle.lastY = cx[1];
    } else if (event.touches.length < 2) {
      this.middle.down = false;
    }
  }

  handlePinch(event: GestureEvent): void {
    this.markActive();
    const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
    this.applyState(Cad.zoom(event.scale / Math.max(0.001, this.lastPinch), p[0], p[1]));
    this.lastPinch = event.scale;
    this.dirty = true;
  }

  handleKey(event: KeyEvent): void {
    this.markActive();
    if (event.keyCode === KeyCode.KEYCODE_CTRL_LEFT || event.keyCode === KeyCode.KEYCODE_CTRL_RIGHT) {
      this.ctrlHeld = event.type === KeyType.Down;
      return;
    }
    if (event.type !== KeyType.Down) {
      return;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.applyState(Cad.cancel());
      this.hotGrip = null;
      this.dirty = true;
    } else if (event.keyCode === KeyCode.KEYCODE_ENTER) {
      this.applyState(Cad.enter());
      this.dirty = true;
    } else if (this.ctrlHeld && event.keyCode === KeyCode.KEYCODE_Z) {
      this.keyword('undo');
    } else if (this.ctrlHeld && event.keyCode === KeyCode.KEYCODE_Y) {
      this.keyword('redo');
    } else if (event.keyCode === KeyCode.KEYCODE_PLUS || event.keyCode === KeyCode.KEYCODE_NUMPAD_ADD) {
      const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
      this.applyState(Cad.zoom(1.25, p[0], p[1]));
      this.dirty = true;
    } else if (event.keyCode === KeyCode.KEYCODE_MINUS || event.keyCode === KeyCode.KEYCODE_NUMPAD_SUBTRACT) {
      const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
      this.applyState(Cad.zoom(0.8, p[0], p[1]));
      this.dirty = true;
    }
  }

  // ---------------- grips ----------------

  /** 夹点命中：点击点（vp）附近 12vp 内的夹点，取最近。 */
  gripAt(xVp: number, yVp: number): CadGrip | null {
    let best: CadGrip | null = null;
    let bestD: number = 12;
    for (const g of this.grips) {
      const scale: number = this.canvasW / this.viewHeightW;
      const gx: number = (g.x - this.viewCenterX) * scale + this.canvasW / 2;
      const gy: number = this.canvasH / 2 - (g.y - this.viewCenterY) * scale;
      const d: number = Math.hypot(gx - xVp, gy - yVp);
      if (d < bestD) {
        bestD = d;
        best = g;
      }
    }
    return best;
  }

  // ---------------- files ----------------

  /** Read a granted file uri (file association / drag & drop) into the engine. */
  openUri(uri: string): boolean {
    try {
      const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const name: string = uri.substring(uri.lastIndexOf('/') + 1);
      this.applyState(Cad.openDxf(name, buf));
      this.dirty = true;
      return true;
    } catch (e) {
      this.showToast(`打开: ${e}`);
      return false;
    }
  }

  async openDxf(): Promise<void> {
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.dxf'];
      const uris: string[] = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      this.openUri(uris[0]);
    } catch (e) {
      this.showToast(`打开: ${e}`);
    }
  }

  private async loadBenchmarkDrawing(): Promise<void> {
    // 文件关联打开（双击 .dxf）优先加载。
    const uri = AppStorage.get<string>('hocadOpenUri');
    AppStorage.setOrCreate('hocadOpenUri', '');
    if (uri && this.openUri(uri)) {
      return;
    }
    // 空白图纸启动，和桌面版一致。不再自动加载基准图。
  }

  async saveDxf(): Promise<void> {
    try {
      const dxf: string = Cad.saveDxf();
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = ['drawing.dxf'];
      const uris: string[] = await docPicker.save(opts);
      if (uris.length === 0) {
        return;
      }
      const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, dxf);
      fs.closeSync(file);
      this.log.push(`已保存 ${uris[0]}`);
    } catch (e) {
      this.showToast(`保存: ${e}`);
    }
  }

  /** 打印当前视图：lastBuf → PixelMap（打印路径按 BGRA 读，先换 R/B）→ PNG → Print Kit。 */
  async printView(): Promise<void> {
    if (this.lastBuf.byteLength === 0) {
      this.showToast('打印: 画布尚未渲染');
      return;
    }
    try {
      const swapped: ArrayBuffer = this.lastBuf.slice(0);
      const px: Uint8Array = new Uint8Array(swapped);
      for (let i = 0; i + 3 < px.length; i += 4) {
        const r = px[i];
        px[i] = px[i + 2];
        px[i + 2] = r;
      }
      const w: number = Math.round(this.canvasW * this.dpr);
      const h: number = Math.round(this.canvasH * this.dpr);
      const size: image.Size = { width: w, height: h };
      const opts: image.InitializationOptions = {
        size: size,
        srcPixelFormat: image.PixelMapFormat.BGRA_8888
      };
      const pm: image.PixelMap = await image.createPixelMap(swapped, opts);
      const pngPath: string = `${getContext(this).filesDir}/hocad-print.png`;
      const file: fs.File = fs.openSync(pngPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const packer: image.ImagePacker = image.createImagePacker();
      const po: image.PackingOption = { format: 'image/png', quality: 100 };
      await packer.packToFile(pm, file.fd, po);
      fs.closeSync(file);
      await pm.release();
      await print.print([pngPath]);
      this.showToast('打印: 已提交系统打印');
    } catch (e) {
      this.showToast(`打印: ${e}`);
    }
  }

  // ---------------- commands ----------------

  submitCmd(): void {
    const text: string = this.cmdText.trim();
    this.cmdText = '';
    this.suggestions = [];
    if (text.length > 0) {
      this.applyState(Cad.cmdline(text));
    } else {
      this.applyState(Cad.enter());
    }
    this.dirty = true;
  }

  keyword(kw: string): void {
    this.applyState(Cad.cmdline(kw));
    this.dirty = true;
  }

  startCommand(name: string): void {
    this.applyState(Cad.start(name));
    this.dirty = true;
  }

  runMenu(id: string): void {
    this.openMenu = -1;
    // 菜单命令统一从命令行走：引擎解析别名并按需启动交互提示，与桌面一致。
    this.applyState(Cad.cmdline(id));
    this.dirty = true;
    // 键盘留在命令行（桌面行为）：Enter 后重新聚焦。
    focusControl.requestFocus('cmdInput');
  }

  /** 图层行 ⋯ 面板的动作（全部走引擎命令：layer.current / layer.set / layer.delete）。 */
  layerAction(act: string): void {
    const name: string = this.ctxLayer;
    const layer = this.layers.find((l: CadLayer) => l.name === name);
    if (act === '置当前') {
      const p: Record<string, string> = { 'name': name };
      this.applyState(Cad.execute('layer.current', p));
    } else if (act === '显示/隐藏') {
      const on = layer ? !layer.on : true;
      const p: Record<string, string | boolean> = { 'name': name, 'on': on };
      this.applyState(Cad.execute('layer.set', p));
    } else if (act === '冻结/解冻') {
      const frozen = layer ? !layer.frozen : true;
      const p: Record<string, string | boolean> = { 'name': name, 'frozen': frozen };
      this.applyState(Cad.execute('layer.set', p));
    } else if (act === '锁定/解锁') {
      const locked = layer ? !layer.locked : true;
      const p: Record<string, string | boolean> = { 'name': name, 'locked': locked };
      this.applyState(Cad.execute('layer.set', p));
    } else if (act === '删除图层') {
      const p: Record<string, string> = { 'name': name };
      this.applyState(Cad.execute('layer.delete', p));
    }
    this.dirty = true;
  }

  // ---------------- UI ----------------

  /** 画布右键菜单（2in1 体验规范：右键菜单或更多操作入口）。 */
  @Builder
  canvasMenu() {
    Menu() {
      MenuItem({ content: '取消 (Esc)' }).onClick(() => {
        this.applyState(Cad.cancel());
        this.dirty = true;
      })
      MenuItem({ content: '缩放范围' }).onClick(() => {
        this.applyState(Cad.zoomExtents());
        this.dirty = true;
      })
      MenuItem({ content: '撤销 (Ctrl+Z)' }).onClick(() => this.keyword('undo'))
      MenuItem({ content: '重做 (Ctrl+Y)' }).onClick(() => this.keyword('redo'))
      MenuItem({ content: '画直线 (LINE)' }).onClick(() => this.startCommand('line'))
      MenuItem({ content: '画圆 (CIRCLE)' }).onClick(() => this.startCommand('circle'))
      MenuItem({ content: this.selection.length > 0 ? '删除选中 (ERASE)' : '删除 (ERASE)' }).onClick(() => {
        if (this.selection.length > 0) {
          this.applyState(Cad.execute('erase', {}));
        } else {
          this.startCommand('erase');
        }
        this.dirty = true;
      })
    }
  }

  @Builder
  menuBar() {
    Row({ space: 2 }) {
      ForEach(this.menus, (m: CadMenu, idx: number) => {
        Button(m.title)
          .fontSize(13).height(28).padding({ left: 10, right: 10 })
          .backgroundColor(this.openMenu === idx ? PANEL_HI : Color.Transparent)
          .fontColor(TEXT)
          .onClick((e: ClickEvent) => {
            this.menuX = Math.max(4, e.x - 10);
            this.openMenu = this.openMenu === idx ? -1 : idx;
          })
      }, (m: CadMenu) => m.title)
      Blank()
      Text('HoCAD').fontSize(13).fontColor(ACCENT).margin({ right: 8 })
    }
    .width('100%')
    .height(34)
    .padding({ left: 8, right: 8 })
  }

  /** 顶部图标条：文件与视图操作。 */
  @Builder
  topIconBar() {
    Row({ space: 10 }) {
      ForEach(TOP_ICONS, (t: ToolDef) => {
        Column({ space: 1 }) {
          Image(t.icon)
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
            .onClick(() => this.runTopTool(t.id))
          Text(t.label)
            .fontSize(8)
            .fontColor(DIM)
        }
        .onClick(() => this.runTopTool(t.id))
        // 长按显示命令说明（工具 tooltip）。
        .gesture(LongPressGesture({ duration: 400, repeat: false })
          .onAction(() => this.showTip(t.desc)))
      }, (t: ToolDef) => t.id)
    }
    .width('100%')
    .height(40)
    .padding({ left: 8, right: 8 })
    .backgroundColor(PANEL)
  }

  runTopTool(id: string): void {
    this.markActive();
    if (id === 'open') {
      this.openDxf();
    } else if (id === 'save') {
      this.saveDxf();
    } else if (id === 'print') {
      this.printView();
    } else if (id === 'undo') {
      this.keyword('undo');
    } else if (id === 'redo') {
      this.keyword('redo');
    } else if (id === 'zoomextents') {
      this.applyState(Cad.zoomExtents());
      this.dirty = true;
    }
  }

  @Builder
  toolIcon(t: ToolDef) {
    Column({ space: 2 }) {
      Image(t.icon)
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
      Text(t.label)
        .fontSize(8)
        .fontColor(DIM)
        .maxLines(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .borderRadius(4)
    .onClick(() => {
      if (t.id === 'hatch') {
        this.hatchOpen = true;
      } else if (t.id === 'mtext') {
        this.mtextOpen = true;
      } else {
        this.startCommand(t.id);
      }
    })
    .gesture(LongPressGesture({ duration: 400, repeat: false })
      .onAction(() => this.showTip(t.desc)))
  }

  @Builder
  toolColumn() {
    Scroll() {
      Column({ space: 0 }) {
        ForEach(TOOL_GROUPS, (group: ToolGroup) => {
          // Group header (click to collapse/expand)
          Row({ space: 6 }) {
            Text('▾')
              .fontSize(10)
              .fontColor(DIM)
              .width(14)
            Text(group.name)
              .fontSize(12)
              .fontColor(TEXT)
              .layoutWeight(1)
          }
          .width('100%')
          .height(24)
          .padding({ left: 8 })
          .backgroundColor(PANEL)
          .onClick(() => {
            // Toggle collapse (simple: hide/show the group body)
            const idx = this.collapsedGroups.indexOf(group.name);
            if (idx >= 0) {
              this.collapsedGroups.splice(idx, 1);
            } else {
              this.collapsedGroups.push(group.name);
            }
          })

          if (!this.collapsedGroups.includes(group.name)) {
            // Large icons row
            Row({ space: 4 }) {
              ForEach(group.large, (t: ToolDef) => {
                Column({ space: 1 }) {
                  if (t.icon) {
                    Image(t.icon)
                      .width(24)
                      .height(24)
                      .objectFit(ImageFit.Contain)
                  } else {
                    Text(t.label.substring(0, 2))
                      .fontSize(14)
                      .fontColor(ACCENT)
                      .height(24)
                      .textAlign(TextAlign.Center)
                  }
                  Text(t.label)
                    .fontSize(7)
                    .fontColor(DIM)
                    .maxLines(1)
                    .textAlign(TextAlign.Center)
                    .width('100%')
                }
                .width(44)
                .padding({ top: 4, bottom: 4 })
                .borderRadius(4)
                .onClick(() => this.runTool(t.id))
                .gesture(LongPressGesture({ duration: 400, repeat: false })
                  .onAction(() => this.showTip(t.desc)))
              }, (t: ToolDef) => t.id)
            }
            .width('100%')
            .padding({ left: 4, right: 4 })
            .justifyContent(FlexAlign.Start)

            // Small icons row (denser)
            if (group.small.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(group.small, (t: ToolDef) => {
                  Text(t.label)
                    .fontSize(9)
                    .fontColor(TEXT)
                    .padding({ left: 5, right: 5, top: 3, bottom: 3 })
                    .borderRadius(3)
                    .backgroundColor(PANEL)
                    .margin(1)
                    .onClick(() => this.runTool(t.id))
                    .gesture(LongPressGesture({ duration: 400, repeat: false })
                      .onAction(() => this.showTip(t.desc)))
                }, (t: ToolDef) => t.id)
              }
              .width('100%')
              .padding({ left: 6, right: 6 })
            }
          }
        }, (group: ToolGroup) => group.name)
      }
      .width('100%')
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
  }

  runTool(id: string): void {
    this.markActive();
    if (id === 'hatch') {
      this.hatchOpen = true;
    } else if (id === 'mtext') {
      this.mtextOpen = true;
    } else {
      this.startCommand(id);
    }
  }

  /** 右侧图层列表：行点击 = 置为当前层；行 ⋯ = 动作面板（CRUD）。 */
  @Builder
  layersPanel() {
    Column({ space: 2 }) {
      Row({ space: 4 }) {
        Text('图层').fontSize(12).fontColor(ACCENT)
        Blank()
        Button('＋')
          .fontSize(11).height(20).padding({ left: 5, right: 5 })
          .backgroundColor(PANEL).fontColor(TEXT)
          .onClick(() => {
            this.layerNewOpen = true;
          })
      }
      .width('100%')
      Scroll() {
        Column({ space: 2 }) {
          ForEach(this.layers, (l: CadLayer) => {
            Row({ space: 4 }) {
              Text('■')
                .fontSize(12)
                .fontColor(l.color.length > 0 ? l.color : '#FFFFFF')
                .width(14)
              Text(this.currentLayer === l.name ? '▸' : ' ')
                .fontSize(12).fontColor(ACCENT).width(12)
              Text(l.name)
                .fontSize(11).fontColor(l.on ? TEXT : DIM)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (l.locked) {
                Text('锁').fontSize(9).fontColor(DIM)
              }
              if (l.frozen) {
                Text('冻').fontSize(9).fontColor(DIM)
              }
              if (!l.on) {
                Text('关').fontSize(9).fontColor(DIM)
              }
              Text('⋯')
                .fontSize(11).fontColor(DIM).width(14)
                .onClick(() => {
                  this.ctxLayer = l.name;
                  this.ctxOpen = true;
                })
            }
            .width('100%')
            .padding({ left: 4, right: 2, top: 3, bottom: 3 })
            .borderRadius(3)
            .backgroundColor(this.currentLayer === l.name ? PANEL_HI : Color.Transparent)
            .onClick(() => {
              const p: Record<string, string> = { 'name': l.name };
              this.applyState(Cad.execute('layer.current', p));
              this.dirty = true;
            })
          }, (l: CadLayer) => `${l.name}-${l.color}-${l.on}-${l.frozen}-${l.locked}-${this.currentLayer}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
    }
    .layoutWeight(1)
  }

  /** 选中集的句柄数组（properties.set 的 handles 参数）。 */
  private selHandles(): number[] {
    return this.selection.map((s: CadSel) => s.handle);
  }

  /** 属性编辑：把字段应用到整个选中集（引擎 properties.set）。 */
  applyProps(field: string, value: string | number): void {
    const handles = this.selHandles();
    if (handles.length === 0) {
      return;
    }
    const p: Record<string, string | number | number[]> = { 'handles': handles };
    p[field] = value;
    this.applyState(Cad.execute('properties.set', p));
    this.dirty = true;
  }

  /** 右侧特性面板：选中集概览 + 图层/颜色编辑。 */
  @Builder
  propertiesPanel() {
    Column({ space: 2 }) {
      Text(`特性 (${this.selection.length})`).fontSize(12).fontColor(ACCENT)
      if (this.selection.length === 0) {
        Text('未选择对象').fontSize(10).fontColor(DIM)
      } else {
        Scroll() {
          Column({ space: 3 }) {
            Text('图层 →').fontSize(9).fontColor(DIM)
            ForEach(this.layers, (l: CadLayer) => {
              Text(l.name)
                .fontSize(10)
                .fontColor(TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 5, top: 3, bottom: 3 })
                .borderRadius(3)
                .backgroundColor(l.name === this.selection[0].layer ? PANEL_HI : PANEL)
                .onClick(() => this.applyProps('layer', l.name))
            }, (l: CadLayer) => `${l.name}-${this.selection[0].layer}`)
            Text('颜色 →').fontSize(9).fontColor(DIM)
            Row({ space: 3 }) {
              ForEach([1, 2, 3, 4, 5, 6, 7], (aci: number) => {
                Text('■')
                  .fontSize(13)
                  .fontColor(['#FF0000', '#FFFF00', '#00FF00', '#00FFFF', '#0000FF', '#FF00FF', '#FFFFFF'][aci - 1])
                  .onClick(() => this.applyProps('color', aci))
              }, (aci: number) => `${aci}`)
            }
            if (this.selection.length === 1 && this.selection[0].kind.startsWith('Circle')) {
              Column({ space: 2 }) {
                Text('半径 →').fontSize(9).fontColor(DIM)
                Row({ space: 4 }) {
                  TextInput({ text: this.geomValue })
                    .width(70).height(24).fontSize(10)
                    .onChange((v: string) => {
                      this.geomValue = v;
                    })
                  Button('应用')
                    .fontSize(9).height(24)
                    .backgroundColor(PANEL).fontColor(TEXT)
                    .onClick(() => {
                      const r = Number(this.geomValue);
                      if (r > 0) {
                        this.applyProps('radius', r);
                      }
                    })
                }
              }
              .width('100%')
            }
            Text('对象列表 →').fontSize(9).fontColor(DIM)
            ForEach(this.selection, (s: CadSel, i: number) => {
              Column({ space: 0 }) {
                Text(`${s.kind} #${s.handle.toString(16).toUpperCase()}`)
                  .fontSize(10).fontColor(TEXT).maxLines(1)
                Text(s.layer).fontSize(9).fontColor(DIM).maxLines(1)
              }
              .width('100%')
              .padding(3)
              .borderRadius(3)
              .backgroundColor(PANEL)
            }, (s: CadSel, i: number) => `${i}-${s.handle}-${s.kind}-${s.layer}`)
          }
          .width('100%')
        }
        .scrollBar(BarState.Auto)
        .layoutWeight(1)
      }
    }
    .layoutWeight(1)
  }

  /** Model/Layout tabs (engine layout.set) + document tabs (session.docs). */
  @Builder
  tabsRow() {
    Row({ space: 2 }) {
      ForEach(['模型'].concat(this.layouts), (name: string) => {
        Button(name)
          .fontSize(11).height(24).padding({ left: 10, right: 10 })
          .backgroundColor(this.spaceName === name ? PANEL_HI : PANEL)
          .fontColor(this.spaceName === name ? ACCENT : DIM)
          .onClick(() => {
            const p: Record<string, string> = { 'option': 'set', 'name': name };
            this.applyState(Cad.execute('layout', p));
            this.dirty = true;
          })
      }, (name: string) => `${name}-${this.spaceName}`)
      Blank()
      ForEach(this.docs, (d: string, i: number) => {
        Row({ space: 1 }) {
          Button(d.length > 0 ? d : `图${i + 1}`)
            .fontSize(11).height(24).padding({ left: 8, right: 4 })
            .backgroundColor(this.docIdx === i ? PANEL_HI : PANEL)
            .fontColor(this.docIdx === i ? ACCENT : DIM)
            .onClick(() => {
              this.applyState(Cad.docSwitch(i));
              this.dirty = true;
            })
          if (this.docs.length > 1) {
            Text('×')
              .fontSize(11).fontColor(DIM)
              .padding({ left: 2, right: 5, top: 4, bottom: 4 })
              .onClick(() => {
                const p: Record<string, number> = { 'index': i };
                this.applyState(Cad.execute('close', p));
                this.dirty = true;
              })
          }
        }
        .backgroundColor(this.docIdx === i ? PANEL_HI : PANEL)
      }, (d: string, i: number) => `${i}-${d}-${this.docIdx}`)
    }
    .width('100%')
    .height(28)
    .padding({ left: 6, right: 6 })
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 4 }) {
          Column() {
            this.toolColumn()
          }
          .width(96)

          Column() {
            this.menuBar()
            this.topIconBar()
            this.tabsRow()

            // Drawing display: Image(pixelMap) 1:1 device pixels + vector overlay +
            // zoom buttons. All input handlers live on the wrapping Stack.
            Stack({ alignContent: Alignment.BottomEnd }) {
              if (this.pixelMap !== null) {
                Image(this.pixelMap)
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Fill)
                  .draggable(false)
                  .autoResize(false)
              }
              Canvas(this.ovlCtx)
                .width('100%')
                .height('100%')
                .hitTestBehavior(HitTestMode.None)
                .onReady(() => this.drawCrosshair())
              Column({ space: 6 }) {
                Button('+')
                  .width(34).height(34).fontSize(18)
                  .backgroundColor(PANEL).fontColor(TEXT)
                  .onClick(() => {
                    const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
                    this.applyState(Cad.zoom(1.25, p[0], p[1]));
                    this.dirty = true;
                  })
                Button('−')
                  .width(34).height(34).fontSize(18)
                  .backgroundColor(PANEL).fontColor(TEXT)
                  .onClick(() => {
                    const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
                    this.applyState(Cad.zoom(0.8, p[0], p[1]));
                    this.dirty = true;
                  })
                Button('⌂')
                  .width(34).height(34).fontSize(14)
                  .backgroundColor(PANEL).fontColor(TEXT)
                  .onClick(() => {
                    this.applyState(Cad.zoomExtents());
                    this.dirty = true;
                  })
              }
              .margin(10)
            }
            .layoutWeight(1)
            .backgroundColor(BG)
            .focusable(true)
            .focusOnTouch(true)
            .onFocus(() => {
              this.canvasFocused = true;
            })
            .onBlur(() => {
              this.canvasFocused = false;
            })
            .border({ width: 1, color: this.canvasFocused ? ACCENT : '#00000000' })
            .onAreaChange((_old: Area, newArea: Area) => {
              this.onCanvasSize(Number(newArea.width), Number(newArea.height));
            })
            .onMouse((event: MouseEvent) => this.handleMouse(event))
            .onTouch((event: TouchEvent) => this.handleTouch(event))
            .onKeyEvent((event: KeyEvent) => this.handleKey(event))
            .allowDrop([uniformTypeDescriptor.UniformDataType.FILE])
            .onDrop((event: DragEvent) => {
              const data: unifiedDataChannel.UnifiedData = event.getData();
              const records: unifiedDataChannel.UnifiedRecord[] = data.getRecords();
              for (const rec of records) {
                const file: unifiedDataChannel.File = rec as unifiedDataChannel.File;
                if (file.uri && file.uri.toLowerCase().endsWith('.dxf')) {
                  this.openUri(file.uri);
                }
              }
            })
            .bindContextMenu(this.canvasMenu, ResponseType.RightClick)
            .gesture(PinchGesture({ fingers: 2 })
              .onActionUpdate((event: GestureEvent) => this.handlePinch(event)))

            // Command line: history + prompt + keywords + suggestions + input.
            Column({ space: 2 }) {
              Row({ space: 6 }) {
                Text(this.prompt.length > 0 ? this.prompt : '命令:')
                  .fontSize(12)
                  .fontColor(ACCENT)
                ForEach(this.keywords, (kw: string) => {
                  Text(kw)
                    .fontSize(11)
                    .fontColor('#8fd8ef')
                    .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                    .borderRadius(3)
                    .backgroundColor(PANEL_HI)
                    .onClick(() => this.keyword(kw))
                }, (kw: string) => kw)
              }
              .width('100%')

              Scroll(this.histScroller) {
                Column({ space: 1 }) {
                  ForEach(this.log, (line: string, i: number) => {
                    Text(line)
                      .fontSize(10)
                      .fontColor(DIM)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .onClick(() => {
                        this.cmdText = line;
                        this.suggestions = [];
                      })
                  }, (line: string, i: number) => `${i}-${line}`)
                }
                .width('100%')
              }
              .scrollBar(BarState.Off)
              .layoutWeight(1)

              if (this.suggestions.length > 0) {
                Row({ space: 4 }) {
                  ForEach(this.suggestions, (id: string) => {
                    Text(id)
                      .fontSize(10)
                      .fontColor(TEXT)
                      .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                      .borderRadius(3)
                      .backgroundColor(PANEL_HI)
                      .onClick(() => {
                        this.cmdText = id;
                        this.suggestions = [];
                      })
                  }, (id: string) => id)
                }
                .width('100%')
              }

              TextInput({ text: this.cmdText, placeholder: '输入命令或坐标，如 circle 0,0 5' })
                .id('cmdInput')
                .width('100%')
                .height(30)
                .fontSize(13)
                .onChange((v: string) => {
                  this.cmdText = v;
                  // 命令补全：按前缀过滤命令 id（最多 6 条，点击填入输入框）。
                  const t = v.trim().toLowerCase();
                  if (t.length > 0) {
                    this.suggestions = this.allIds.filter((id: string) => id.startsWith(t)).slice(0, 6);
                  } else {
                    this.suggestions = [];
                  }
                })
                .onSubmit(() => this.submitCmd())
            }
            .width('100%')
            .height(130)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(PANEL)

            if (this.toast.length > 0) {
              Text(this.toast)
                .fontSize(11)
                .fontColor('#ffd4a0')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(4)
                .backgroundColor('rgba(0,0,0,0.6)')
                .position({ x: 12, y: this.canvasH - 40 })
            }
            Row({ space: 8 }) {
              Text(this.coordsText.length > 0 ? this.coordsText : '0.00, 0.00')
                .fontSize(11)
                .fontColor(TEXT)
                .layoutWeight(1)
              Button('正交')
                .fontSize(10).height(22).padding({ left: 6, right: 6 })
                .backgroundColor(this.ortho ? ACCENT : PANEL)
                .fontColor(this.ortho ? '#0b1a20' : DIM)
                .onClick(() => {
                  const p: Record<string, string | number> = {
                    'name': 'ORTHOMODE', 'value': this.ortho ? 0 : 1
                  };
                  this.applyState(Cad.execute('setvar', p));
                })
              Button('捕捉')
                .fontSize(10).height(22).padding({ left: 6, right: 6 })
                .backgroundColor(this.osnap ? ACCENT : PANEL)
                .fontColor(this.osnap ? '#0b1a20' : DIM)
                .onClick(() => {
                  const p: Record<string, string | number> = {
                    'name': 'OSMODE', 'value': this.osnap ? 0 : 4133
                  };
                  this.applyState(Cad.execute('setvar', p));
                })
              Button('缩放窗')
                .fontSize(10).height(22).padding({ left: 5, right: 5 })
                .backgroundColor(this.zoomWinMode ? ACCENT : PANEL)
                .fontColor(this.zoomWinMode ? '#0b1a20' : DIM)
                .onClick(() => {
                  this.zoomWinMode = !this.zoomWinMode;
                  this.zoomWinFirst = null;
                })
              Button(this.gridOn ? '栅格 ✓' : '栅格')
                .fontSize(10).height(22).padding({ left: 6, right: 6 })
                .backgroundColor(PANEL).fontColor(DIM)
                .onClick(() => {
                  this.gridOn = !this.gridOn;
                  this.dirty = true;
                })
              Text(this.status).fontSize(10).fontColor(DIM)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(2)
            }
            .width('100%')
            .height(26)
            .padding({ left: 8, right: 8 })
          }
          .layoutWeight(1)

          // 右侧面板：图层 CRUD + 特性（只读 v1）。
          Column({ space: 4 }) {
            this.layersPanel()
            this.propertiesPanel()
          }
          .width(130)
          .padding(4)
          .backgroundColor(BG)
        }
        .layoutWeight(1)

        // 系统下拉菜单（真菜单栏）：点空白关闭的遮罩。
        if (this.openMenu >= 0 && this.openMenu < this.menus.length) {
          Column()
            .width('100%')
            .height('100%')
            .onClick(() => {
              this.openMenu = -1;
            })
        }
        if (this.openMenu >= 0 && this.openMenu < this.menus.length) {
          Column({ space: 1 }) {
            ForEach(this.menus[this.openMenu].items, (it: CadMenuItem) => {
              Row({ space: 6 }) {
                Text(it.label)
                  .fontSize(12)
                  .fontColor(TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (it.key) {
                  Text(it.key).fontSize(10).fontColor(DIM)
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .borderRadius(3)
              .onClick(() => this.runMenu(it.id))
            }, (it: CadMenuItem) => `${it.id}-${it.label}`)
          }
          .width(260)
          .padding(4)
          .borderRadius(6)
          .backgroundColor(PANEL_HI)
          .shadow({ radius: 12, color: 'rgba(0,0,0,0.5)', offsetY: 4 })
          .position({ x: this.menuX, y: 36 })
        }

        // 工具 tooltip（长按图标显示）。
        if (this.tipText.length > 0) {
          Text(this.tipText)
            .fontSize(11)
            .fontColor(TEXT)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(5)
            .backgroundColor(PANEL_HI)
            .shadow({ radius: 8, color: 'rgba(0,0,0,0.4)', offsetY: 2 })
            .position({ x: 108, y: 84 })
        }

        // 图层动作面板（图层行 ⋯ 打开）。
        if (this.ctxOpen) {
          Column()
            .width('100%')
            .height('100%')
            .onClick(() => {
              this.ctxOpen = false;
            })
        }
        if (this.ctxOpen) {
          Column({ space: 1 }) {
            Text(this.ctxLayer).fontSize(11).fontColor(ACCENT).padding(6)
            ForEach(['置当前', '显示/隐藏', '冻结/解冻', '锁定/解锁', '删除图层'], (act: string) => {
              Text(act)
                .fontSize(12).fontColor(TEXT)
                .width('100%')
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .onClick(() => {
                  this.layerAction(act);
                  this.ctxOpen = false;
                })
            }, (act: string) => act)
          }
          .width(180)
          .padding(4)
          .borderRadius(6)
          .backgroundColor(PANEL_HI)
          .shadow({ radius: 12, color: 'rgba(0,0,0,0.5)', offsetY: 4 })
          .position({ x: 100, y: 120 })
        }

        // 新建图层弹窗。
        if (this.layerNewOpen) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.4)')
            .onClick(() => {
              this.layerNewOpen = false;
            })
        }
        if (this.layerNewOpen) {
          Column({ space: 8 }) {
            Text('新建图层').fontSize(14).fontColor(TEXT)
            TextInput({ placeholder: '图层名' })
              .width(200)
              .height(34)
              .onChange((v: string) => {
                this.newLayerName = v;
              })
            Row({ space: 8 }) {
              Button('取消')
                .fontSize(12).height(30)
                .backgroundColor(PANEL).fontColor(TEXT)
                .onClick(() => {
                  this.layerNewOpen = false;
                  this.newLayerName = '';
                })
              Button('创建')
                .fontSize(12).height(30)
                .backgroundColor(ACCENT).fontColor('#0b1a20')
                .onClick(() => {
                  const name = this.newLayerName.trim();
                  if (name.length > 0) {
                    const p: Record<string, string | boolean> = { 'name': name, 'current': true };
                    this.applyState(Cad.execute('layer.new', p));
                    this.dirty = true;
                  }
                  this.layerNewOpen = false;
                  this.newLayerName = '';
                })
            }
          }
          .padding(14)
          .borderRadius(8)
          .backgroundColor(PANEL_HI)
          .position({ x: 180, y: 200 })
        }

        // HATCH 对话框：图案/比例/角度 → 确认后点画布放内部点。
        if (this.hatchOpen) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.4)')
            .onClick(() => {
              this.hatchOpen = false;
            })
        }
        if (this.hatchOpen) {
          Column({ space: 8 }) {
            Text('填充 (HATCH)').fontSize(14).fontColor(TEXT)
            Text('图案').fontSize(10).fontColor(DIM)
            Scroll() {
              Row({ space: 4 }) {
                ForEach(['SOLID', 'ANSI31', 'ANSI32', 'ANSI33', 'ANSI34', 'ANSI35', 'ANSI36', 'ANSI37', 'ANSI38'],
                  (name: string) => {
                    Text(name)
                      .fontSize(10)
                      .fontColor(this.hatchPattern === name ? ACCENT : TEXT)
                      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                      .borderRadius(3)
                      .border({ width: 1, color: this.hatchPattern === name ? ACCENT : '#3a4450' })
                      .onClick(() => {
                        this.hatchPattern = name;
                      })
                  }, (name: string) => name)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .width('100%')
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text('比例').fontSize(10).fontColor(DIM)
                TextInput({ text: this.hatchScale })
                  .width(80).height(30).fontSize(12)
                  .onChange((v: string) => {
                    this.hatchScale = v;
                  })
              }
              Column({ space: 2 }) {
                Text('角度').fontSize(10).fontColor(DIM)
                TextInput({ text: this.hatchAngle })
                  .width(80).height(30).fontSize(12)
                  .onChange((v: string) => {
                    this.hatchAngle = v;
                  })
              }
            }
            .width('100%')
            Button('确定 → 点画布放置')
              .fontSize(12).height(32)
              .backgroundColor(ACCENT).fontColor('#0b1a20')
              .onClick(() => {
                this.hatchOpen = false;
                this.pendingPlace = 'hatch';
              })
          }
          .padding(14)
          .borderRadius(8)
          .backgroundColor(PANEL_HI)
          .position({ x: this.canvasW / 2 - 150, y: 120 })
        }

        // MTEXT 对话框：内容/字高 → 确认后点画布放插入点。
        if (this.mtextOpen) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.4)')
            .onClick(() => {
              this.mtextOpen = false;
            })
        }
        if (this.mtextOpen) {
          Column({ space: 8 }) {
            Text('多行文字 (MTEXT)').fontSize(14).fontColor(TEXT)
            TextInput({ text: this.mtextText })
              .width('100%')
              .height(34)
              .fontSize(12)
              .onChange((v: string) => {
                this.mtextText = v;
              })
            Column({ space: 2 }) {
              Text('字高').fontSize(10).fontColor(DIM)
              TextInput({ text: this.mtextHeight })
                .width(80).height(30).fontSize(12)
                .onChange((v: string) => {
                  this.mtextHeight = v;
                })
            }
            Button('确定 → 点画布放置')
              .fontSize(12).height(32)
              .backgroundColor(ACCENT).fontColor('#0b1a20')
              .onClick(() => {
                this.mtextOpen = false;
                this.pendingPlace = 'mtext';
              })
          }
          .padding(14)
          .borderRadius(8)
          .backgroundColor(PANEL_HI)
          .position({ x: this.canvasW / 2 - 150, y: 120 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(BG)
    }
    .width('100%')
    .height('100%')
  }
}
