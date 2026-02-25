import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'mainTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(0x0000, 'mainTag', '%{public}s', 'Ability onDestroy');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    hilog.info(0x0000, 'mainTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'mainTag', 'Failed to load the content: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, 'mainTag', 'Succeeded in loading the content');
    });

    try {
      let mainWindow = await windowStage.getMainWindow();
      hilog.info(0x0000, 'mainTag', 'Succeeded in getting main window');
      await mainWindow.setWindowKeepScreenOn(true);
      hilog.info(0x0000, 'mainTag', 'Succeeded in keeping screen on');

      // 沉浸式布局（API 12+ 同步接口）：内容延伸到状态栏和导航栏区域
      mainWindow.setImmersiveModeEnabledState(true);
      hilog.info(0x0000, 'mainTag', 'Succeeded in setting immersive mode');

      // 系统栏：全透明背景 + 深色图标 + 切换动画
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: '#FF000000',
        isStatusBarLightIcon: false,
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FF000000',
        isNavigationBarLightIcon: false,
        enableStatusBarAnimation: true,
        enableNavigationBarAnimation: true,
      });
      hilog.info(0x0000, 'mainTag', 'Succeeded in setting system bar properties');
    } catch (err) {
      hilog.error(0x0000, 'mainTag', 'Window setup failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, 'mainTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, 'mainTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, 'mainTag', '%{public}s', 'Ability onBackground');
  }
}
