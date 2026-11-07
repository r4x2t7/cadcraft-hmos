// HoCAD HarmonyOS shell (2in1 / PC + tablet): thin ArkUI front end over the Rust engine.
// Panels read engine state (cadState) and act through Cad* calls — the same discipline as
// the egui UI crate ("the UI is thin"). Canvas frames come from the CPU rasteriser, like
// the web and plot paths.
//
// All pointer coordinates handed to Cad are DEVICE pixels (vp × densityPixels).

import { Cad, CadState, CadView } from '../bridge/CadBridge';
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
const ACCENT: string = '#14a3c7';
const ACTIVE_MS: number = 1500; // pointer/key recency that keeps the render loop at 60fps

class MiddleDrag {
  down: boolean = false;
  lastX: number = 0;
  lastY: number = 0;
}

@Entry
@Component
struct Index {
  @State prompt: string = '';
  @State keywords: string[] = [];
  @State log: string[] = [];
  @State status: string = '';
  @State cmdText: string = '';
  @State canvasFocused: boolean = false;
  @State lastPinch: number = 1;
  @State frameMs: string = '';
  private settings: RenderingContextSettings = new RenderingContextSettings(false);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private pixelMap: image.PixelMap | null = null;
  private frameWidth: number = 0;
  private frameHeight: number = 0;
  private dpr: number = 1;
  private canvasW: number = 0; // vp
  private canvasH: number = 0; // vp
  private middle: MiddleDrag = new MiddleDrag();
  private ctrlHeld: boolean = false;
  private dirty: boolean = true;
  private frames: number = 0;
  private lastActive: number = 0;
  private rateHigh: boolean = false;
  // Accumulated pan offset (device px) since the last full frame — used to blit the old
  // frame shifted during pans so navigation keeps the display instantly responsive.
  private panAccX: number = 0;
  private panAccY: number = 0;
  // DisplaySync-driven render loop (replaces a setInterval poll): VSync-aligned, with a
  // frame-rate range the tick switches between interactive (60fps) and idle (5fps).
  // Created in aboutToAppear — constructing it as a field initializer runs before the UI
  // context exists and its frame callback never fires.
  private renderer: displaySync.DisplaySync | null = null;
  private lastTickAt: number = 0;
  private fallbackTimer: number = -1;

  aboutToAppear(): void {
    this.dpr = display.getDefaultDisplaySync().densityPixels;
    const state: CadState = Cad.init();
    this.applyState(state);
    this.renderer = displaySync.create();
    this.renderer.on('frame', () => this.tick());
    this.renderer.setExpectedFrameRateRange({ min: 5, max: 120, expected: 60 });
    // Some emulator images never fire DisplaySync frames: tick liveness check hands the
    // loop to a 100ms interval whenever DisplaySync stalls (real devices keep 60fps).
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
    // Frame-rate gear: 60fps while interacting/prompting, 5fps idle (power best practice).
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

  applyState(state: CadState): void {
    if (!state.ok && state.error) {
      this.status = `错误: ${state.error}`;
    }
    this.prompt = state.prompt ? state.prompt.message : '';
    this.keywords = state.prompt ? state.prompt.keywords : [];
    if (state.log.length > 0) {
      this.log = state.log.slice(-8);
    }
    if (state.frameMs !== undefined && state.frameMs > 0) {
      const vis: string = (state.visible !== undefined && state.total !== undefined && state.visible < state.total)
        ? ` ${state.visible}/${state.total}`
        : '';
      this.frameMs = `渲染 ${state.frameMs.toFixed(0)}ms (建 ${state.buildMs?.toFixed(0) ?? '?'} + 画 ${state.rasterMs?.toFixed(0) ?? '?'}${vis})`;
    }
    const view: CadView = state.view;
    this.status =
      `视图高 ${view.height.toFixed(2)} | 中心 (${view.center[0].toFixed(2)}, ${view.center[1].toFixed(2)}) | ${this.frameMs}`;
  }

  // ---------------- canvas ----------------

  onCanvasReady(): void {
    this.canvasW = this.context.width;
    this.canvasH = this.context.height;
    hilog.info(0x0000, 'cadcraft', 'onCanvasReady %{public}dx%{public}d', this.canvasW, this.canvasH);
    Cad.resize(this.canvasW * this.dpr, this.canvasH * this.dpr);
    this.dirty = true;
  }

  async drawFrame(): Promise<void> {
    const w: number = Math.round(this.canvasW * this.dpr);
    const h: number = Math.round(this.canvasH * this.dpr);
    if (w < 16 || h < 16) {
      hilog.warn(0x0000, 'cadcraft', 'drawFrame skip %{public}dx%{public}d', w, h);
      return;
    }
    Cad.resize(w, h);
    const buf: ArrayBuffer = Cad.frame();
    if (buf.byteLength === 0) {
      return;
    }
    try {
      if (this.pixelMap === null || this.frameWidth !== w || this.frameHeight !== h) {
        if (this.pixelMap !== null) {
          await this.pixelMap.release();
        }
        const size: image.Size = { width: w, height: h };
        // The Rust side emits premultiplied BGRA (see apps/cadcraft-ohos/src/render.rs).
        const opts: image.InitializationOptions = {
          size: size,
          srcPixelFormat: image.PixelMapFormat.BGRA_8888
        };
        this.pixelMap = await image.createPixelMap(buf, opts);
        this.frameWidth = w;
        this.frameHeight = h;
      } else {
        const region: image.Region = { size: { width: w, height: h }, x: 0, y: 0 };
        const area: image.PositionArea = { pixels: buf, offset: 0, stride: w * 4, region: region };
        await this.pixelMap.writePixels(area);
      }
      this.context.drawImage(this.pixelMap, 0, 0, this.canvasW, this.canvasH);
      this.panAccX = 0;
      this.panAccY = 0;
    } catch (e) {
      this.status = `渲染: ${e}`;
    }
  }

  /** Instant pan feedback: blit the last full frame shifted by the accumulated pan. */
  blitPanned(): void {
    if (this.pixelMap === null || (this.panAccX === 0 && this.panAccY === 0)) {
      return;
    }
    this.context.fillStyle = BG;
    this.context.fillRect(0, 0, this.canvasW, this.canvasH);
    this.context.drawImage(this.pixelMap, this.panAccX / this.dpr, this.panAccY / this.dpr,
      this.canvasW, this.canvasH);
  }

  device(xVp: number, yVp: number): number[] {
    return [xVp * this.dpr, yVp * this.dpr];
  }

  // ---------------- interactions ----------------

  handleMouse(event: MouseEvent): void {
    this.markActive();
    const p: number[] = this.device(event.x, event.y);
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
        this.blitPanned();
        this.dirty = this.frames % 3 === 0; // full re-render throttled; blit keeps it smooth
      } else {
        this.dirty = true; // cursor previews (rubber band)
      }
      return;
    }
    if (event.action === MouseAction.Press) {
      if (event.button === MouseButton.Middle) {
        this.middle.down = true;
        this.middle.lastX = p[0];
        this.middle.lastY = p[1];
        // 右键交给 bindContextMenu（2in1 体验规范要求右键菜单）；菜单内含"取消 (Esc)"。
      } else if (event.button === MouseButton.Left) {
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
    // Single tap = click; two-finger drag = pan (with old-frame blit); pinch zoom is a
    // PinchGesture below.
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
        this.panAccX += cx[0] - this.middle.lastX;
        this.panAccY += cx[1] - this.middle.lastY;
        Cad.pan(cx[0] - this.middle.lastX, cx[1] - this.middle.lastY);
        this.blitPanned();
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
    // Track Ctrl ourselves: ArkTS KeyEvent carries no modifier state in this SDK.
    if (event.keyCode === KeyCode.KEYCODE_CTRL_LEFT || event.keyCode === KeyCode.KEYCODE_CTRL_RIGHT) {
      this.ctrlHeld = event.type === KeyType.Down;
      return;
    }
    if (event.type !== KeyType.Down) {
      return;
    }
    // 快捷键（2in1 体验规范）：画布聚焦时 Esc/Enter，Ctrl+Z/Ctrl+Y 走自跟踪的 ctrlHeld。
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.applyState(Cad.cancel());
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
      this.status = `打开: ${e}`;
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
      this.status = `打开: ${e}`;
    }
  }

  /** Dev benchmark: load the packed thunder.dxf (rawfile) at startup. Keep small. */
  private async loadBenchmarkDrawing(): Promise<void> {
    // 文件关联打开的图优先于基准图；打不开（残留 uri、文件已删）再落回基准图。
    const uri = AppStorage.get<string>('hocadOpenUri');
    AppStorage.setOrCreate('hocadOpenUri', '');
    if (uri && this.openUri(uri)) {
      return;
    }
    try {
      const raw: Uint8Array =
        await getContext(this).resourceManager.getRawFileContent('thunder.dxf');
      const buf: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);
      this.applyState(Cad.openDxf('thunder.dxf', buf));
      this.dirty = true;
    } catch (e) {
      // No thunder.dxf packed in this build — start on the empty drawing.
    }
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
      this.status = `保存: ${e}`;
    }
  }

  /** 打印当前视图：pixelMap → PNG in sandbox → 系统打印（Print Kit）。 */
  async printView(): Promise<void> {
    if (this.pixelMap === null) {
      this.status = '打印: 画布尚未渲染';
      return;
    }
    try {
      const pngPath: string = `${getContext(this).filesDir}/hocad-print.png`;
      const file: fs.File = fs.openSync(pngPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const packer: image.ImagePacker = image.createImagePacker();
      const opts: image.PackingOption = { format: 'image/png', quality: 100 };
      await packer.packToFile(this.pixelMap, file.fd, opts);
      fs.closeSync(file);
      await print.print([pngPath]);
      this.status = '打印: 已提交系统打印';
    } catch (e) {
      this.status = `打印: ${e}`;
    }
  }

  // ---------------- commands ----------------

  submitCmd(): void {
    const text: string = this.cmdText.trim();
    this.cmdText = '';
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
      MenuItem({ content: '删除 (ERASE)' }).onClick(() => this.startCommand('erase'))
    }
  }

  @Builder
  menuBar() {
    Row({ space: 4 }) {
      Button('打开')
        .fontSize(13).height(30).padding({ left: 10, right: 10 })
        .backgroundColor(PANEL).fontColor('#dfe6ee')
        .onClick(() => this.openDxf())
      Button('保存')
        .fontSize(13).height(30).padding({ left: 10, right: 10 })
        .backgroundColor(PANEL).fontColor('#dfe6ee')
        .onClick(() => this.saveDxf())
      Button('打印')
        .fontSize(13).height(30).padding({ left: 10, right: 10 })
        .backgroundColor(PANEL).fontColor('#dfe6ee')
        .onClick(() => this.printView())
      Button('缩放范围')
        .fontSize(13).height(30).padding({ left: 10, right: 10 })
        .backgroundColor(PANEL).fontColor('#dfe6ee')
        .onClick(() => {
          this.applyState(Cad.zoomExtents());
          this.dirty = true;
        })
      Button('UNDO')
        .fontSize(13).height(30).padding({ left: 10, right: 10 })
        .backgroundColor(PANEL).fontColor('#dfe6ee')
        .onClick(() => this.keyword('undo'))
      Button('REDO')
        .fontSize(13).height(30).padding({ left: 10, right: 10 })
        .backgroundColor(PANEL).fontColor('#dfe6ee')
        .onClick(() => this.keyword('redo'))
      Blank()
      Text('HoCAD').fontSize(13).fontColor(ACCENT).margin({ right: 8 })
    }
    .width('100%')
    .height(36)
    .padding({ left: 6, right: 6 })
  }

  @Builder
  toolColumn() {
    Scroll() {
      Column({ space: 4 }) {
        Text('绘图').fontSize(12).fontColor(ACCENT).margin({ top: 8 })
        ForEach(['line', 'circle', 'arc', 'mtext', 'dimlinear', 'hatch'], (c: string) => {
          Button(c.toUpperCase())
            .width(88)
            .height(30)
            .fontSize(12)
            .backgroundColor(PANEL)
            .fontColor('#dfe6ee')
            .onClick(() => this.startCommand(c))
        }, (c: string) => c)
        Text('修改').fontSize(12).fontColor(ACCENT).margin({ top: 8 })
        ForEach(['erase', 'move', 'copy', 'offset', 'trim'], (c: string) => {
          Button(c.toUpperCase())
            .width(88)
            .height(30)
            .fontSize(12)
            .backgroundColor(PANEL)
            .fontColor('#dfe6ee')
            .onClick(() => this.startCommand(c))
        }, (c: string) => c)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
  }

  build() {
    Row({ space: 4 }) {
      Column() {
        this.toolColumn()
      }
      .width(100)

      Column() {
        this.menuBar()

        // Canvas: click to pick, middle-drag / two-finger pan (old-frame blit), pinch zoom,
        // right-click menu, drag & drop a DXF to open.
        Stack({ alignContent: Alignment.BottomEnd }) {
          Canvas(this.context)
            .width('100%')
            .height('100%')
            .backgroundColor(BG)
            .onReady(() => this.onCanvasReady())
            .onMouse((event: MouseEvent) => this.handleMouse(event))
            .onTouch((event: TouchEvent) => this.handleTouch(event))
            .onKeyEvent((event: KeyEvent) => this.handleKey(event))
            // 焦点反馈（2in1 体验规范）：画布聚焦时描边高亮；点击即聚焦使快捷键生效。
            .focusable(true)
            .focusOnTouch(true)
            .onFocus(() => {
              this.canvasFocused = true;
            })
            .onBlur(() => {
              this.canvasFocused = false;
            })
            .border({ width: 1, color: this.canvasFocused ? ACCENT : '#00000000' })
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
          // 触屏/注入用缩放钮：+ / − / 缩放范围（键鼠走滚轮与右键菜单）。
          Column({ space: 6 }) {
            Button('+')
              .width(34).height(34).fontSize(18)
              .backgroundColor(PANEL).fontColor('#dfe6ee')
              .onClick(() => {
                const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
                this.applyState(Cad.zoom(1.25, p[0], p[1]));
                this.dirty = true;
              })
            Button('−')
              .width(34).height(34).fontSize(18)
              .backgroundColor(PANEL).fontColor('#dfe6ee')
              .onClick(() => {
                const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
                this.applyState(Cad.zoom(0.8, p[0], p[1]));
                this.dirty = true;
              })
            Button('⌂')
              .width(34).height(34).fontSize(14)
              .backgroundColor(PANEL).fontColor('#dfe6ee')
              .onClick(() => {
                this.applyState(Cad.zoomExtents());
                this.dirty = true;
              })
          }
          .margin(10)
        }
        .layoutWeight(1)

        // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(this.prompt.length > 0 ? this.prompt : '命令:')
              .fontSize(13)
              .fontColor(ACCENT)
            ForEach(this.keywords, (kw: string) => {
              Text(kw)
                .fontSize(12)
                .fontColor('#8fd8ef')
                .padding(4)
                .border({ width: 1, color: '#3a4450', radius: 4 })
                .onClick(() => this.keyword(kw))
            }, (kw: string) => kw)
          }
          .width('100%')
          .padding({ left: 6, right: 6 })

          TextInput({ text: this.cmdText, placeholder: '输入命令或坐标，如 circle 0,0 5' })
            .width('100%')
            .height(32)
            .fontSize(13)
            .onChange((v: string) => {
              this.cmdText = v;
            })
            .onSubmit(() => this.submitCmd())

          ForEach(this.log.slice(-4), (line: string) => {
            Text(line)
              .fontSize(11)
              .fontColor('#9fb0c0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 6 })
          }, (line: string, i: number) => `${i}-${line}`)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .backgroundColor(PANEL)

        Text(this.status)
          .fontSize(11)
          .fontColor('#7d8ea0')
          .width('100%')
          .height(20)
          .padding({ left: 6 })
      }
      .layoutWeight(1)

      // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
      Column({ space: 4 }) {
        Text('视图').fontSize(12).fontColor(ACCENT).margin({ top: 8 })
        Text(this.status).fontSize(10).fontColor('#9fb0c0')
        Text('图层').fontSize(12).fontColor(ACCENT).margin({ top: 12 })
        Text('v2: 图层 / 特性面板\n（engine 直驱）').fontSize(10).fontColor('#7d8ea0')
      }
      .width(120)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(BG)
      .padding(6)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }
}
