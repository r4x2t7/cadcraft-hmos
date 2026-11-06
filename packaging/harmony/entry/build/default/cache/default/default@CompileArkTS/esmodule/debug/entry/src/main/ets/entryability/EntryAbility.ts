import type AbilityConstant from "@ohos:app.ability.AbilityConstant";
import UIAbility from "@ohos:app.ability.UIAbility";
import type Want from "@ohos:app.ability.Want";
import hilog from "@ohos:hilog";
import type window from "@ohos:window";
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
            // setWindowMinSize 已由 setWindowLimits 的 minWidth/minHeight 取代（API 15+）。
            windowStage.getMainWindow()
                .then((win: window.Window): Promise<window.WindowLimits> => win.setWindowLimits({ minWidth: MIN_WINDOW_VP, minHeight: MIN_WINDOW_HEIGHT_VP }))
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
