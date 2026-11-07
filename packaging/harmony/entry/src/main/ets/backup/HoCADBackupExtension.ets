import { BackupExtensionAbility } from '@kit.CoreFileKit';

// 系统备份/恢复入口：备份范围由 resources/base/profile/backup_config.json 声明
// （files/ = 打开的图纸与打印输出），本类保持空实现走默认流程。
export default class HoCADBackupExtension extends BackupExtensionAbility {
}
