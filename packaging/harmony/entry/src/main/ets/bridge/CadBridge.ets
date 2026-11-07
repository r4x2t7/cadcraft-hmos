/**
 * The Node-API bridge to the Rust engine (`apps/cadcraft-ohos`).
 *
 * All coordinate arguments are DEVICE pixels relative to the canvas, origin top-left;
 * Index.ets multiplies by the display density before calling in.
 */
import native from 'libcadcraft_ohos.so';

export interface CadPrompt {
  message: string;
  keywords: string[];
}

export interface CadView {
  center: number[];
  height: number;
}

export interface CadCanvas {
  width: number;
  height: number;
}

export interface CadLayer {
  name: string;
  color: string;
  on: boolean;
  frozen: boolean;
  locked: boolean;
}

export interface CadSel {
  kind: string;
  layer: string;
}

export interface CadMenuItem {
  label: string;
  id: string;
  key?: string;
}

export interface CadMenu {
  title: string;
  items: CadMenuItem[];
}

export interface CadState {
  ok: boolean;
  error?: string;
  epoch: number;
  frameMs?: number;
  buildMs?: number;
  rasterMs?: number;
  visible?: number;
  total?: number;
  prompting: boolean;
  prompt: CadPrompt | null;
  view: CadView;
  canvas: CadCanvas;
  layers: CadLayer[];
  currentLayer: string;
  selection: CadSel[];
  space: string;
  layouts: string[];
  docs: string[];
  doc: number;
  ortho: boolean;
  osnap: boolean;
  window: number[] | null;
  result?: object;
  log: string[];
}

const EMPTY_VIEW: CadView = { center: [0, 0], height: 10 };
const EMPTY_CANVAS: CadCanvas = { width: 0, height: 0 };

function parse(json: string): CadState {
  let state: CadState;
  try {
    state = JSON.parse(json) as CadState;
  } catch (e) {
    state = {
      ok: false, error: `${e}`, epoch: 0, prompting: false, prompt: null,
      view: EMPTY_VIEW, canvas: EMPTY_CANVAS, log: [], layers: [], currentLayer: '',
      selection: [], space: '', layouts: [], docs: [], doc: 0,
      ortho: false, osnap: false, window: null
    };
  }
  if (!state.view) {
    state.view = EMPTY_VIEW;
  }
  if (!state.canvas) {
    state.canvas = EMPTY_CANVAS;
  }
  if (!state.log) {
    state.log = [];
  }
  if (!state.prompt) {
    state.prompt = null;
  }
  if (!state.layers) {
    state.layers = [];
  }
  if (!state.selection) {
    state.selection = [];
  }
  if (!state.currentLayer) {
    state.currentLayer = '';
  }
  if (!state.layouts) {
    state.layouts = [];
  }
  if (!state.docs) {
    state.docs = [];
  }
  if (!state.window) {
    state.window = null;
  }
  return state;
}

export class Cad {
  static init(): CadState {
    return parse(native.cadInit() as string);
  }

  /** The engine menu tree, flattened per top menu; the menubar is built from it. */
  static menus(): CadMenu[] {
    try {
      return JSON.parse(native.cadMenus() as string) as CadMenu[];
    } catch (e) {
      return [];
    }
  }

  static resize(w: number, h: number): void {
    native.cadResize(w, h);
  }

  static execute(command: string, params: Record<string, string | number | boolean> | null): CadState {
    return parse(native.cadExecute(command, params === null ? '' : JSON.stringify(params)) as string);
  }

  static cmdline(text: string): CadState {
    return parse(native.cadCmdline(text) as string);
  }

  /** Start an interactive command by id (toolbar buttons), like the desktop's app.start(id). */
  static start(commandId: string): CadState {
    return parse(native.cadStart(commandId) as string);
  }

  static enter(): CadState {
    return parse(native.cadEnter() as string);
  }

  static cancel(): CadState {
    return parse(native.cadCancel() as string);
  }

  static click(x: number, y: number, shift: boolean, ctrl: boolean): CadState {
    return parse(native.cadClick(x, y, shift ? 1 : 0, ctrl ? 1 : 0) as string);
  }

  static move(x: number, y: number): void {
    native.cadMove(x, y);
  }

  static zoom(factor: number, x: number, y: number): CadState {
    return parse(native.cadZoom(factor, x, y) as string);
  }

  static pan(dx: number, dy: number): void {
    native.cadPan(dx, dy);
  }

  static zoomExtents(): CadState {
    return parse(native.cadZoomExtents() as string);
  }

  static openDxf(name: string, bytes: ArrayBuffer): CadState {
    return parse(native.cadOpenDxf(name, bytes) as string);
  }

  static saveDxf(): string {
    return native.cadSaveDxf() as string;
  }

  /** Switch the active document tab. */
  static docSwitch(index: number): CadState {
    return parse(native.cadDocSwitch(index) as string);
  }

  static state(): CadState {
    return parse(native.cadState() as string);
  }

  /** RGBA_8888 pixels of the current view; empty buffer when the surface is not ready. */
  static frame(): ArrayBuffer {
    return native.cadFrame() as ArrayBuffer;
  }
}
