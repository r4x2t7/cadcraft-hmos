// CADCraft HarmonyOS shell (2in1 / PC + tablet): thin ArkUI front end over the Rust engine.
// Panels read engine state (cadState) and act through Cad* calls — the same discipline as
// the egui UI crate ("the UI is thin"). Canvas frames come from the CPU rasteriser, like
// the web and plot paths.
//
// All pointer coordinates handed to Cad are DEVICE pixels (vp × densityPixels).

import { Cad, CadState } from '../bridge/CadBridge';
import { picker } from '@kit.CoreFileKit';
import { fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

const BG: string = '#212830';
const PANEL: string = '#2a323c';
const ACCENT: string = '#14a3c7';

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
  private settings: RenderingContextSettings = new RenderingContextSettings(false);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private pixelMap: image.PixelMap | null = null;
  private frameWidth: number = 0;
  private frameHeight: number = 0;
  private dpr: number = 1;
  private canvasW: number = 0; // vp
  private canvasH: number = 0; // vp
  private middle: MiddleDrag = new MiddleDrag();
  private dirty: boolean = true;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.dpr = display.getDefaultDisplaySync().densityPixels;
    const state: CadState = Cad.init();
    this.applyState(state);
    // 10 Hz poll: prompt/log/epoch changes plus redraws when dirty. Interaction events
    // also mark dirty for an immediate refresh at the next tick.
    this.timerId = setInterval(() => this.tick(), 100);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
  }

  tick(): void {
    if (this.dirty) {
      this.dirty = false;
      this.drawFrame();
    }
    this.applyState(Cad.state());
  }

  applyState(state: CadState): void {
    if (!state.ok && state.error) {
      this.status = `错误: ${state.error}`;
    }
    this.prompt = state.prompt ? state.prompt.message : '';
    this.keywords = state.prompt ? state.prompt.keywords : [];
    if (state.log && state.log.length > 0) {
      this.log = state.log.slice(-8);
    }
    const view = state.view;
    this.status = `实体 ${state.epoch} | 视图高 ${view.height.toFixed(2)} | 视图中心 (${view.center[0].toFixed(2)}, ${view.center[1].toFixed(2)})`;
  }

  // ---------------- canvas ----------------

  onCanvasReady(): void {
    // Canvas reports its vp size once laid out; resize the engine to the device-pixel size.
    this.canvasW = this.context.width;
    this.canvasH = this.context.height;
    Cad.resize(this.canvasW * this.dpr, this.canvasH * this.dpr);
    this.dirty = true;
  }

  async drawFrame(): Promise<void> {
    const w: number = Math.round(this.canvasW * this.dpr);
    const h: number = Math.round(this.canvasH * this.dpr);
    if (w < 16 || h < 16) {
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
        this.pixelMap = await image.createPixelMap(buf, {
          size: { width: w, height: h },
          format: image.PixelMapFormat.RGBA_8888,
          srcPixelFormat: image.PixelMapFormat.RGBA_8888
        });
        this.frameWidth = w;
        this.frameHeight = h;
      } else {
        await this.pixelMap.writePixels({
          pixels: buf, offset: 0, stride: w * 4,
          region: { x: 0, y: 0, width: w, height: h }
        });
      }
      this.context.drawImage(this.pixelMap, 0, 0, this.canvasW, this.canvasH);
    } catch (e) {
      this.status = `渲染: ${e}`;
    }
  }

  device(xVp: number, yVp: number): number[] {
    return [xVp * this.dpr, yVp * this.dpr];
  }

  // ---------------- interactions ----------------

  onMouse(event: MouseEvent): void {
    const p = this.device(event.x, event.y);
    if (event.action === MouseAction.Move) {
      Cad.move(p[0], p[1]);
      if (this.middle.down) {
        Cad.pan(p[0] - this.middle.lastX, p[1] - this.middle.lastY);
        this.middle.lastX = p[0];
        this.middle.lastY = p[1];
        this.dirty = true;
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
        this.applyState(Cad.click(p[0], p[1], false, false));
        this.dirty = true;
      }
      return;
    }
    if (event.action === MouseAction.Release) {
      if (event.button === MouseButton.Middle) {
        this.middle.down = false;
      }
    }
  }

  onTouch(event: TouchEvent): void {
    // Single tap = click; two-finger drag = pan; pinch zoom is a PinchGesture below.
    if (event.type === TouchType.Up && event.touches.length === 0 && event.changedTouches.length >= 1) {
      const t = event.changedTouches[0];
      const p = this.device(t.x, t.y);
      this.applyState(Cad.click(p[0], p[1], false, false));
      this.dirty = true;
    } else if (event.type === TouchType.Move && event.touches.length === 2) {
      const a = event.touches[0];
      const b = event.touches[1];
      const cx = this.device((a.x + b.x) / 2, (a.y + b.y) / 2);
      // Track the previous two-finger midpoint on the gesture state.
      if (this.middle.down) {
        Cad.pan(cx[0] - this.middle.lastX, cx[1] - this.middle.lastY);
        this.dirty = true;
      }
      this.middle.down = true;
      this.middle.lastX = cx[0];
      this.middle.lastY = cx[1];
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (event.touches.length < 2) {
        this.middle.down = false;
      }
    }
  }

  onPinch(event: PinchEvent): void {
    const cx = this.canvasW / 2;
    const cy = this.canvasH / 2;
    const p = this.device(cx, cy);
    // pinch scale is cumulative since the gesture started; zoom factor = new/old.
    this.applyState(Cad.zoom(event.scale / Math.max(0.001, this.lastPinch), p[0], p[1]));
    this.lastPinch = event.scale;
    this.dirty = true;
  }

  onKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) {
      return;
    }
    // 快捷键（2in1 体验规范）：画布聚焦时 Esc/Enter/Ctrl+Z/Ctrl+Y 直达命令行语义。
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.applyState(Cad.cancel());
      this.dirty = true;
    } else if (event.keyCode === KeyCode.KEYCODE_ENTER) {
      this.applyState(Cad.enter());
      this.dirty = true;
    } else if (event.isCtrlPressed && event.keyCode === KeyCode.KEYCODE_Z) {
      this.keyword('undo');
    } else if (event.isCtrlPressed && event.keyCode === KeyCode.KEYCODE_Y) {
      this.keyword('redo');
    }
  }

  // ---------------- commands ----------------

  submitCmd(): void {
    const text = this.cmdText.trim();
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
  async openDxf(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker();
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.dxf'];
      const uris = await docPicker.select(opts);
      if (!uris || uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const name = uri.substring(uri.lastIndexOf('/') + 1);
      this.applyState(Cad.openDxf(name, buf));
      this.dirty = true;
    } catch (e) {
      this.status = `打开: ${e}`;
    }
  }

  async saveDxf(): Promise<void> {
    try {
      const dxf: string = Cad.saveDxf();
      const docPicker = new picker.DocumentViewPicker();
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = ['drawing.dxf'];
      const uri = await docPicker.save(opts);
      if (!uri || uri.length === 0) {
        return;
      }
      const file = fs.openSync(uri[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, dxf);
      fs.closeSync(file);
      this.log.push(`已保存 ${uri[0]}`);
    } catch (e) {
      this.status = `保存: ${e}`;
    }
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

  menuButton(label: string, action: () => void): Button {
    return Button(label)
      .fontSize(13)
      .height(30)
      .padding({ left: 10, right: 10 })
      .backgroundColor(PANEL)
      .fontColor('#dfe6ee')
      .onClick(() => action());
  }

  build() {
    Row({ space: 4 }) {
      // Tool Sets (left) — the same commands the desktop's Tool Sets panel starts.
      Column({ space: 4 }) {
        Text('绘图').fontSize(12).fontColor(ACCENT).margin({ top: 8 })
        ForEach(['line', 'circle', 'arc', 'mtext', 'dimlinear', 'hatch'], (c: string) => {
          Button(c.toUpperCase())
            .width(88).height(30).fontSize(12)
            .backgroundColor(PANEL).fontColor('#dfe6ee')
            .onClick(() => this.startCommand(c))
        }, (c: string) => c)
        Text('修改').fontSize(12).fontColor(ACCENT).margin({ top: 8 })
        ForEach(['erase', 'move', 'copy', 'offset', 'trim'], (c: string) => {
          Button(c.toUpperCase())
            .width(88).height(30).fontSize(12)
            .backgroundColor(PANEL).fontColor('#dfe6ee')
            .onClick(() => this.startCommand(c))
        }, (c: string) => c)
      }
      .width(100)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(BG)
      .scrollable(ScrollDirection.Vertical)

      Column() {
        // Menu bar
        Row({ space: 4 }) {
          this.menuButton('打开', () => this.openDxf())
          this.menuButton('保存', () => this.saveDxf())
          this.menuButton('缩放范围', () => {
            this.applyState(Cad.zoomExtents());
            this.dirty = true;
          })
          this.menuButton('UNDO', () => this.keyword('undo'))
          this.menuButton('REDO', () => this.keyword('redo'))
          Blank()
          Text('HoCAD').fontSize(13).fontColor(ACCENT).margin({ right: 8 })
        }
        .width('100%').height(36).padding({ left: 6, right: 6 })

        // Canvas: click to pick, middle-drag / two-finger pan, pinch or wheel-free zoom.
        Column() {
          Canvas(this.context)
            .width('100%')
            .height('100%')
            .backgroundColor(BG)
            .onReady(() => this.onCanvasReady())
            .onMouse((event: MouseEvent) => this.onMouse(event))
            .onTouch((event: TouchEvent) => this.onTouch(event))
            .onKeyEvent((event: KeyEvent) => this.onKey(event))
            // 焦点反馈（2in1 体验规范）：画布聚焦时描边高亮；点击即聚焦使快捷键生效。
            .focusable(true)
            .focusOnTouch(true)
            .onFocus(() => { this.canvasFocused = true; })
            .onBlur(() => { this.canvasFocused = false; })
            .border({ width: 1, color: this.canvasFocused ? ACCENT : '#00000000' })
            .bindContextMenu(this.canvasMenu, ResponseType.RightClick)
            .gesture(PinchGesture({ fingers: 2 })
              .onActionUpdate((event: GestureEvent) => this.onPinch(event as PinchEvent)))
        }
        .layoutWeight(1)

        // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(this.prompt.length > 0 ? this.prompt : '命令:').fontSize(13).fontColor(ACCENT)
            ForEach(this.keywords, (kw: string) => {
              Text(kw).fontSize(12).fontColor('#8fd8ef')
                .padding(4).border({ width: 1, color: '#3a4450', radius: 4 })
                .onClick(() => this.keyword(kw))
            }, (kw: string) => kw)
          }
          .width('100%').padding({ left: 6, right: 6 })

          TextInput({ text: this.cmdText, placeholder: '输入命令或坐标，如 circle 0,0 5' })
            .width('100%').height(32).fontSize(13)
            .onChange((v: string) => { this.cmdText = v; })
            .onSubmit(() => this.submitCmd())

          ForEach(this.log.slice(-4), (line: string) => {
            Text(line).fontSize(11).fontColor('#9fb0c0').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').padding({ left: 6 })
          }, (line: string, i: number) => `${i}-${line}`)
        }
        .width('100%').padding({ top: 4, bottom: 4 })
        .backgroundColor(PANEL)

        Text(this.status).fontSize(11).fontColor('#7d8ea0')
          .width('100%').height(20).padding({ left: 6 })
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
