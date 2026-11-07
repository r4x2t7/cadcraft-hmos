import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const MIN_WINDOW_VP: number = 480;
const MIN_WINDOW_HEIGHT_VP: number = 320;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'cadcraft', 'onCreate');
    // 文件关联/拖到图标启动：want.uri 是被打开的 DXF。
    this.handleWant(want);
    // 命令行参数与 --sample 之类启动参数以后走 want.parameters。
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已在运行时再次双击 .dxf：直接换图。
    this.handleWant(want);
  }

  handleWant(want: Want): void {
    const uri = want.uri;
    if (uri && uri.toLowerCase().endsWith('.dxf')) {
      AppStorage.setOrCreate('hocadOpenUri', uri);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'cadcraft', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, 'cadcraft', 'loaded pages/Index');
      // 自由窗口规范：声明最小尺寸（vp），缩小窗口时布局仍可读。
      // setWindowMinSize 已由 setWindowLimits 的 minWidth/minHeight 取代（API 15+）。
      windowStage.getMainWindow()
        .then((win: window.Window): Promise<window.WindowLimits> => win.setWindowLimits(
          { minWidth: MIN_WINDOW_VP, minHeight: MIN_WINDOW_HEIGHT_VP }))
        .catch((e: Error): void => {
          hilog.warn(0x0000, 'cadcraft', 'setWindowLimits unavailable: %{public}s', `${e}`);
        });
    });
  }

  onWindowStageDestroy(): void {
    // TODO: 退出前把当前图自动存到 filesDir（恢复用），与桌面端"永不丢图"一致。
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
