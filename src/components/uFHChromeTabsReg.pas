unit uFHChromeTabsReg;

{==============================================================================
  FHChromeTabs 设计时注册单元
  ----------------------------------------------------------------------------
  - 仅被组件包 FHChromeTabsPkg contains; 组件单元本体零设计期依赖
    （不 uses DesignIntf）, Demo/宿主工程直接 uses 组件单元即可编译
  - 注册面板: FHChromeTabs 页（文档 NFR-6）
  - 除标签条/页面容器外, 同时注册 Chrome 风格 UI 控件（导航按钮/地址栏/
    窗口按钮）——原实现这三个控件不在包内, 无法在设计器里使用
  - 正式分发拆 runtime/designtime 双包时, 本单元归 designtime 包
==============================================================================}

interface

procedure Register;

implementation

uses
  System.Classes,   // RegisterComponents 的真实声明位置（不在 DesignIntf 里）
  DesignIntf, uFHChromeTabs, uFHChromePageHost, uFHBrowserControls;

procedure Register;
begin
  RegisterComponents('FHChromeTabs',
    [TFHChromeTabs, TFHChromePageHost,
     TFHNavButton, TFHAddressBar, TFHCaptionButton]);
end;

end.
