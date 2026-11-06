import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const MIN_WINDOW_VP: number = 480;
const MIN_WINDOW_HEIGHT_VP: number = 320;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'cadcraft', 'onCreate');
    // 命令行参数与 --sample 之类启动参数以后走 want.parameters。
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'cadcraft', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, 'cadcraft', 'loaded pages/Index');
      // 自由窗口规范：声明最小尺寸（vp），缩小窗口时布局仍可读。
      // setWindowMinSize 在个别版本不可见，失败不致命，吞掉（2in1 上也可改用
      // setWindowLimits(..., isForcible: true)，API 15+）。
      windowStage.getMainWindow()
        .then((win: window.Window) => win.setWindowMinSize(
          { windowWidth: MIN_WINDOW_VP, windowHeight: MIN_WINDOW_HEIGHT_VP }))
        .catch((e: Error) => {
          hilog.warn(0x0000, 'cadcraft', 'setWindowMinSize unavailable: %{public}s', `${e}`);
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
