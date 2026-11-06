if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Index_Params {
    prompt?: string;
    keywords?: string[];
    log?: string[];
    status?: string;
    cmdText?: string;
    canvasFocused?: boolean;
    lastPinch?: number;
    settings?: RenderingContextSettings;
    context?: CanvasRenderingContext2D;
    pixelMap?: image.PixelMap | null;
    frameWidth?: number;
    frameHeight?: number;
    dpr?: number;
    canvasW?: number;
    canvasH?: number;
    middle?: MiddleDrag;
    ctrlHeld?: boolean;
    dirty?: boolean;
    timerId?: number;
}
import { Cad } from "@bundle:io.github.r4x2t7.hocad/entry/ets/bridge/CadBridge";
import type { CadState, CadView } from "@bundle:io.github.r4x2t7.hocad/entry/ets/bridge/CadBridge";
import picker from "@ohos:file.picker";
import fs from "@ohos:file.fs";
import image from "@ohos:multimedia.image";
import display from "@ohos:display";
import { KeyCode } from "@ohos:multimodalInput.keyCode";
const BG: string = '#212830';
const PANEL: string = '#2a323c';
const ACCENT: string = '#14a3c7';
class MiddleDrag {
    down: boolean = false;
    lastX: number = 0;
    lastY: number = 0;
}
class Index extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__prompt = new ObservedPropertySimplePU('', this, "prompt");
        this.__keywords = new ObservedPropertyObjectPU([], this, "keywords");
        this.__log = new ObservedPropertyObjectPU([], this, "log");
        this.__status = new ObservedPropertySimplePU('', this, "status");
        this.__cmdText = new ObservedPropertySimplePU('', this, "cmdText");
        this.__canvasFocused = new ObservedPropertySimplePU(false, this, "canvasFocused");
        this.__lastPinch = new ObservedPropertySimplePU(1, this, "lastPinch");
        this.settings = new RenderingContextSettings(false);
        this.context = new CanvasRenderingContext2D(this.settings);
        this.pixelMap = null;
        this.frameWidth = 0;
        this.frameHeight = 0;
        this.dpr = 1;
        this.canvasW = 0;
        this.canvasH = 0;
        this.middle = new MiddleDrag();
        this.ctrlHeld = false;
        this.dirty = true;
        this.timerId = -1;
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Index_Params) {
        if (params.prompt !== undefined) {
            this.prompt = params.prompt;
        }
        if (params.keywords !== undefined) {
            this.keywords = params.keywords;
        }
        if (params.log !== undefined) {
            this.log = params.log;
        }
        if (params.status !== undefined) {
            this.status = params.status;
        }
        if (params.cmdText !== undefined) {
            this.cmdText = params.cmdText;
        }
        if (params.canvasFocused !== undefined) {
            this.canvasFocused = params.canvasFocused;
        }
        if (params.lastPinch !== undefined) {
            this.lastPinch = params.lastPinch;
        }
        if (params.settings !== undefined) {
            this.settings = params.settings;
        }
        if (params.context !== undefined) {
            this.context = params.context;
        }
        if (params.pixelMap !== undefined) {
            this.pixelMap = params.pixelMap;
        }
        if (params.frameWidth !== undefined) {
            this.frameWidth = params.frameWidth;
        }
        if (params.frameHeight !== undefined) {
            this.frameHeight = params.frameHeight;
        }
        if (params.dpr !== undefined) {
            this.dpr = params.dpr;
        }
        if (params.canvasW !== undefined) {
            this.canvasW = params.canvasW;
        }
        if (params.canvasH !== undefined) {
            this.canvasH = params.canvasH;
        }
        if (params.middle !== undefined) {
            this.middle = params.middle;
        }
        if (params.ctrlHeld !== undefined) {
            this.ctrlHeld = params.ctrlHeld;
        }
        if (params.dirty !== undefined) {
            this.dirty = params.dirty;
        }
        if (params.timerId !== undefined) {
            this.timerId = params.timerId;
        }
    }
    updateStateVars(params: Index_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__prompt.purgeDependencyOnElmtId(rmElmtId);
        this.__keywords.purgeDependencyOnElmtId(rmElmtId);
        this.__log.purgeDependencyOnElmtId(rmElmtId);
        this.__status.purgeDependencyOnElmtId(rmElmtId);
        this.__cmdText.purgeDependencyOnElmtId(rmElmtId);
        this.__canvasFocused.purgeDependencyOnElmtId(rmElmtId);
        this.__lastPinch.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__prompt.aboutToBeDeleted();
        this.__keywords.aboutToBeDeleted();
        this.__log.aboutToBeDeleted();
        this.__status.aboutToBeDeleted();
        this.__cmdText.aboutToBeDeleted();
        this.__canvasFocused.aboutToBeDeleted();
        this.__lastPinch.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __prompt: ObservedPropertySimplePU<string>;
    get prompt() {
        return this.__prompt.get();
    }
    set prompt(newValue: string) {
        this.__prompt.set(newValue);
    }
    private __keywords: ObservedPropertyObjectPU<string[]>;
    get keywords() {
        return this.__keywords.get();
    }
    set keywords(newValue: string[]) {
        this.__keywords.set(newValue);
    }
    private __log: ObservedPropertyObjectPU<string[]>;
    get log() {
        return this.__log.get();
    }
    set log(newValue: string[]) {
        this.__log.set(newValue);
    }
    private __status: ObservedPropertySimplePU<string>;
    get status() {
        return this.__status.get();
    }
    set status(newValue: string) {
        this.__status.set(newValue);
    }
    private __cmdText: ObservedPropertySimplePU<string>;
    get cmdText() {
        return this.__cmdText.get();
    }
    set cmdText(newValue: string) {
        this.__cmdText.set(newValue);
    }
    private __canvasFocused: ObservedPropertySimplePU<boolean>;
    get canvasFocused() {
        return this.__canvasFocused.get();
    }
    set canvasFocused(newValue: boolean) {
        this.__canvasFocused.set(newValue);
    }
    private __lastPinch: ObservedPropertySimplePU<number>;
    get lastPinch() {
        return this.__lastPinch.get();
    }
    set lastPinch(newValue: number) {
        this.__lastPinch.set(newValue);
    }
    private settings: RenderingContextSettings;
    private context: CanvasRenderingContext2D;
    private pixelMap: image.PixelMap | null;
    private frameWidth: number;
    private frameHeight: number;
    private dpr: number;
    private canvasW: number; // vp
    private canvasH: number; // vp
    private middle: MiddleDrag;
    private ctrlHeld: boolean;
    private dirty: boolean;
    private timerId: number;
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
        if (state.log.length > 0) {
            this.log = state.log.slice(-8);
        }
        const view: CadView = state.view;
        this.status =
            `视图高 ${view.height.toFixed(2)} | 中心 (${view.center[0].toFixed(2)}, ${view.center[1].toFixed(2)})`;
    }
    // ---------------- canvas ----------------
    onCanvasReady(): void {
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
                const size: image.Size = { width: w, height: h };
                const opts: image.InitializationOptions = {
                    size: size,
                    pixelFormat: image.PixelMapFormat.RGBA_8888,
                    srcPixelFormat: image.PixelMapFormat.RGBA_8888
                };
                this.pixelMap = await image.createPixelMap(buf, opts);
                this.frameWidth = w;
                this.frameHeight = h;
            }
            else {
                const region: image.Region = { size: { width: w, height: h }, x: 0, y: 0 };
                const area: image.PositionArea = { pixels: buf, offset: 0, stride: w * 4, region: region };
                await this.pixelMap.writePixels(area);
            }
            this.context.drawImage(this.pixelMap, 0, 0, this.canvasW, this.canvasH);
        }
        catch (e) {
            this.status = `渲染: ${e}`;
        }
    }
    device(xVp: number, yVp: number): number[] {
        return [xVp * this.dpr, yVp * this.dpr];
    }
    // ---------------- interactions ----------------
    handleMouse(event: MouseEvent): void {
        const p: number[] = this.device(event.x, event.y);
        if (event.action === MouseAction.Move) {
            Cad.move(p[0], p[1]);
            if (this.middle.down) {
                Cad.pan(p[0] - this.middle.lastX, p[1] - this.middle.lastY);
                this.middle.lastX = p[0];
                this.middle.lastY = p[1];
                this.dirty = true;
            }
            else {
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
            }
            else if (event.button === MouseButton.Left) {
                this.applyState(Cad.click(p[0], p[1], false, this.ctrlHeld));
                this.dirty = true;
            }
            return;
        }
        if (event.action === MouseAction.Release && event.button === MouseButton.Middle) {
            this.middle.down = false;
        }
    }
    handleTouch(event: TouchEvent): void {
        // Single tap = click; two-finger drag = pan; pinch zoom is a PinchGesture below.
        if (event.type === TouchType.Up && event.changedTouches.length >= 1) {
            const t: TouchObject = event.changedTouches[0];
            const p: number[] = this.device(t.x, t.y);
            this.applyState(Cad.click(p[0], p[1], false, false));
            this.dirty = true;
        }
        else if (event.type === TouchType.Move && event.touches.length === 2) {
            const a: TouchObject = event.touches[0];
            const b: TouchObject = event.touches[1];
            const cx: number[] = this.device((a.x + b.x) / 2, (a.y + b.y) / 2);
            if (this.middle.down) {
                Cad.pan(cx[0] - this.middle.lastX, cx[1] - this.middle.lastY);
                this.dirty = true;
            }
            this.middle.down = true;
            this.middle.lastX = cx[0];
            this.middle.lastY = cx[1];
        }
        else if (event.touches.length < 2) {
            this.middle.down = false;
        }
    }
    handlePinch(event: GestureEvent): void {
        const p: number[] = this.device(this.canvasW / 2, this.canvasH / 2);
        this.applyState(Cad.zoom(event.scale / Math.max(0.001, this.lastPinch), p[0], p[1]));
        this.lastPinch = event.scale;
        this.dirty = true;
    }
    handleKey(event: KeyEvent): void {
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
        }
        else if (event.keyCode === KeyCode.KEYCODE_ENTER) {
            this.applyState(Cad.enter());
            this.dirty = true;
        }
        else if (this.ctrlHeld && event.keyCode === KeyCode.KEYCODE_Z) {
            this.keyword('undo');
        }
        else if (this.ctrlHeld && event.keyCode === KeyCode.KEYCODE_Y) {
            this.keyword('redo');
        }
    }
    // ---------------- commands ----------------
    submitCmd(): void {
        const text: string = this.cmdText.trim();
        this.cmdText = '';
        if (text.length > 0) {
            this.applyState(Cad.cmdline(text));
        }
        else {
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
            const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
            const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
            opts.maxSelectNumber = 1;
            opts.fileSuffixFilters = ['.dxf'];
            const uris: string[] = await docPicker.select(opts);
            if (uris.length === 0) {
                return;
            }
            const uri: string = uris[0];
            const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
            const stat: fs.Stat = fs.statSync(file.fd);
            const buf: ArrayBuffer = new ArrayBuffer(stat.size);
            fs.readSync(file.fd, buf);
            fs.closeSync(file);
            const name: string = uri.substring(uri.lastIndexOf('/') + 1);
            this.applyState(Cad.openDxf(name, buf));
            this.dirty = true;
        }
        catch (e) {
            this.status = `打开: ${e}`;
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
        }
        catch (e) {
            this.status = `保存: ${e}`;
        }
    }
    // ---------------- UI ----------------
    /** 画布右键菜单（2in1 体验规范：右键菜单或更多操作入口）。 */
    canvasMenu(parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Menu.create();
        }, Menu);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '取消 (Esc)' });
            MenuItem.onClick(() => {
                this.applyState(Cad.cancel());
                this.dirty = true;
            });
        }, MenuItem);
        MenuItem.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '缩放范围' });
            MenuItem.onClick(() => {
                this.applyState(Cad.zoomExtents());
                this.dirty = true;
            });
        }, MenuItem);
        MenuItem.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '撤销 (Ctrl+Z)' });
            MenuItem.onClick(() => this.keyword('undo'));
        }, MenuItem);
        MenuItem.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '重做 (Ctrl+Y)' });
            MenuItem.onClick(() => this.keyword('redo'));
        }, MenuItem);
        MenuItem.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '画直线 (LINE)' });
            MenuItem.onClick(() => this.startCommand('line'));
        }, MenuItem);
        MenuItem.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '画圆 (CIRCLE)' });
            MenuItem.onClick(() => this.startCommand('circle'));
        }, MenuItem);
        MenuItem.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            MenuItem.create({ content: '删除 (ERASE)' });
            MenuItem.onClick(() => this.startCommand('erase'));
        }, MenuItem);
        MenuItem.pop();
        Menu.pop();
    }
    menuBar(parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 4 });
            Row.width('100%');
            Row.height(36);
            Row.padding({ left: 6, right: 6 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('打开');
            Button.fontSize(13);
            Button.height(30);
            Button.padding({ left: 10, right: 10 });
            Button.backgroundColor(PANEL);
            Button.fontColor('#dfe6ee');
            Button.onClick(() => this.openDxf());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('保存');
            Button.fontSize(13);
            Button.height(30);
            Button.padding({ left: 10, right: 10 });
            Button.backgroundColor(PANEL);
            Button.fontColor('#dfe6ee');
            Button.onClick(() => this.saveDxf());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('缩放范围');
            Button.fontSize(13);
            Button.height(30);
            Button.padding({ left: 10, right: 10 });
            Button.backgroundColor(PANEL);
            Button.fontColor('#dfe6ee');
            Button.onClick(() => {
                this.applyState(Cad.zoomExtents());
                this.dirty = true;
            });
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('UNDO');
            Button.fontSize(13);
            Button.height(30);
            Button.padding({ left: 10, right: 10 });
            Button.backgroundColor(PANEL);
            Button.fontColor('#dfe6ee');
            Button.onClick(() => this.keyword('undo'));
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('REDO');
            Button.fontSize(13);
            Button.height(30);
            Button.padding({ left: 10, right: 10 });
            Button.backgroundColor(PANEL);
            Button.fontColor('#dfe6ee');
            Button.onClick(() => this.keyword('redo'));
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('HoCAD');
            Text.fontSize(13);
            Text.fontColor(ACCENT);
            Text.margin({ right: 8 });
        }, Text);
        Text.pop();
        Row.pop();
    }
    toolColumn(parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Scroll.create();
            Scroll.scrollable(ScrollDirection.Vertical);
            Scroll.scrollBar(BarState.Auto);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 4 });
            Column.width('100%');
            Column.alignItems(HorizontalAlign.Center);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('绘图');
            Text.fontSize(12);
            Text.fontColor(ACCENT);
            Text.margin({ top: 8 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const c = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Button.createWithLabel(c.toUpperCase());
                    Button.width(88);
                    Button.height(30);
                    Button.fontSize(12);
                    Button.backgroundColor(PANEL);
                    Button.fontColor('#dfe6ee');
                    Button.onClick(() => this.startCommand(c));
                }, Button);
                Button.pop();
            };
            this.forEachUpdateFunction(elmtId, ['line', 'circle', 'arc', 'mtext', 'dimlinear', 'hatch'], forEachItemGenFunction, (c: string) => c, false, false);
        }, ForEach);
        ForEach.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('修改');
            Text.fontSize(12);
            Text.fontColor(ACCENT);
            Text.margin({ top: 8 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const c = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Button.createWithLabel(c.toUpperCase());
                    Button.width(88);
                    Button.height(30);
                    Button.fontSize(12);
                    Button.backgroundColor(PANEL);
                    Button.fontColor('#dfe6ee');
                    Button.onClick(() => this.startCommand(c));
                }, Button);
                Button.pop();
            };
            this.forEachUpdateFunction(elmtId, ['erase', 'move', 'copy', 'offset', 'trim'], forEachItemGenFunction, (c: string) => c, false, false);
        }, ForEach);
        ForEach.pop();
        Column.pop();
        Scroll.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 4 });
            Row.width('100%');
            Row.height('100%');
            Row.backgroundColor(BG);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width(100);
        }, Column);
        this.toolColumn.bind(this)();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.layoutWeight(1);
        }, Column);
        this.menuBar.bind(this)();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // Canvas: click to pick, middle-drag / two-finger pan, pinch zoom, right-click menu.
            Column.create();
            // Canvas: click to pick, middle-drag / two-finger pan, pinch zoom, right-click menu.
            Column.layoutWeight(1);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Canvas.create(this.context);
            Canvas.width('100%');
            Canvas.height('100%');
            Canvas.backgroundColor(BG);
            Canvas.onReady(() => this.onCanvasReady());
            Canvas.onMouse((event: MouseEvent) => this.handleMouse(event));
            Canvas.onTouch((event: TouchEvent) => this.handleTouch(event));
            Canvas.onKeyEvent((event: KeyEvent) => this.handleKey(event));
            Canvas.focusable(true);
            Canvas.focusOnTouch(true);
            Canvas.onFocus(() => {
                this.canvasFocused = true;
            });
            Canvas.onBlur(() => {
                this.canvasFocused = false;
            });
            Canvas.border({ width: 1, color: this.canvasFocused ? ACCENT : '#00000000' });
            Canvas.bindContextMenu({ builder: this.canvasMenu.bind(this) }, ResponseType.RightClick);
            globalThis.Gesture.create(GesturePriority.Low);
            PinchGesture.create({ fingers: 2 });
            PinchGesture.onActionUpdate((event: GestureEvent) => this.handlePinch(event));
            PinchGesture.pop();
            globalThis.Gesture.pop();
        }, Canvas);
        Canvas.pop();
        // Canvas: click to pick, middle-drag / two-finger pan, pinch zoom, right-click menu.
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
            Column.create({ space: 2 });
            // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
            Column.width('100%');
            // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
            Column.padding({ top: 4, bottom: 4 });
            // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
            Column.backgroundColor(PANEL);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 6 });
            Row.width('100%');
            Row.padding({ left: 6, right: 6 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.prompt.length > 0 ? this.prompt : '命令:');
            Text.fontSize(13);
            Text.fontColor(ACCENT);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const kw = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(kw);
                    Text.fontSize(12);
                    Text.fontColor('#8fd8ef');
                    Text.padding(4);
                    Text.border({ width: 1, color: '#3a4450', radius: 4 });
                    Text.onClick(() => this.keyword(kw));
                }, Text);
                Text.pop();
            };
            this.forEachUpdateFunction(elmtId, this.keywords, forEachItemGenFunction, (kw: string) => kw, false, false);
        }, ForEach);
        ForEach.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ text: this.cmdText, placeholder: '输入命令或坐标，如 circle 0,0 5' });
            TextInput.width('100%');
            TextInput.height(32);
            TextInput.fontSize(13);
            TextInput.onChange((v: string) => {
                this.cmdText = v;
            });
            TextInput.onSubmit(() => this.submitCmd());
        }, TextInput);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const line = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(line);
                    Text.fontSize(11);
                    Text.fontColor('#9fb0c0');
                    Text.maxLines(1);
                    Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                    Text.width('100%');
                    Text.padding({ left: 6 });
                }, Text);
                Text.pop();
            };
            this.forEachUpdateFunction(elmtId, this.log.slice(-4), forEachItemGenFunction, (line: string, i: number) => `${i}-${line}`, false, true);
        }, ForEach);
        ForEach.pop();
        // Command line: prompt + keywords + input + history, like the desktop's bottom strip.
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.status);
            Text.fontSize(11);
            Text.fontColor('#7d8ea0');
            Text.width('100%');
            Text.height(20);
            Text.padding({ left: 6 });
        }, Text);
        Text.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
            Column.create({ space: 4 });
            // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
            Column.width(120);
            // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
            Column.alignItems(HorizontalAlign.Start);
            // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
            Column.backgroundColor(BG);
            // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
            Column.padding(6);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('视图');
            Text.fontSize(12);
            Text.fontColor(ACCENT);
            Text.margin({ top: 8 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.status);
            Text.fontSize(10);
            Text.fontColor('#9fb0c0');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('图层');
            Text.fontSize(12);
            Text.fontColor(ACCENT);
            Text.margin({ top: 12 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('v2: 图层 / 特性面板\n（engine 直驱）');
            Text.fontSize(10);
            Text.fontColor('#7d8ea0');
        }, Text);
        Text.pop();
        // Properties (right) — v1 shows live view/state; layers/styles read via cadState in v2.
        Column.pop();
        Row.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    public __resetStateVarsOnReuse__Internal(params: Object): void {
    }
    static getEntryName(): string {
        return "Index";
    }
}
registerNamedRoute(() => new Index(undefined, {}), "", { bundleName: "io.github.r4x2t7.hocad", moduleName: "entry", pagePath: "pages/Index", pageFullPath: "entry/src/main/ets/pages/Index", integratedHsp: "false", moduleType: "followWithHap" });
