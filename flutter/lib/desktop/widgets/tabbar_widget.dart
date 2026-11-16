import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide TabBarTheme;
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/pages/view_camera_page.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:get/get_rx/src/rx_workers/utils/debouncer.dart';
import 'package:http/http.dart' as http;
import 'package:scroll_pos/scroll_pos.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../utils/multi_window_manager.dart';

const double _kTabBarHeight = kDesktopRemoteTabBarHeight;
const double _kIconSize = 18;
const double _kDividerIndent = 10;
const double _kActionIconSize = 12;

class TabInfo {
  final String key; // Notice: cm use client_id.toString() as key
  final String label;
  final IconData? selectedIcon;
  final IconData? unselectedIcon;
  final bool closable;
  final VoidCallback? onTabCloseButton;
  final VoidCallback? onTap;
  final Widget page;

  TabInfo(
      {required this.key,
      required this.label,
      this.selectedIcon,
      this.unselectedIcon,
      this.closable = true,
      this.onTabCloseButton,
      this.onTap,
      required this.page});
}

enum DesktopTabType {
  main,
  cm,
  remoteScreen,
  fileTransfer,
  viewCamera,
  portForward,
  terminal,
  install,
}

class DesktopTabState {
  final List<TabInfo> tabs = [];
  final ScrollPosController scrollController =
      ScrollPosController(itemCount: 0);
  final PageController pageController = PageController();
  int selected = 0;

  TabInfo get selectedTabInfo => tabs[selected];

  DesktopTabState() {
    scrollController.itemCount = tabs.length;
  }
}

CancelFunc showRightMenu(ToastBuilder builder,
    {BuildContext? context, Offset? target}) {
  return BotToast.showAttachedWidget(
    target: target,
    targetContext: context,
    verticalOffset: 0.0,
    horizontalOffset: 0.0,
    duration: Duration(seconds: 300),
    animationDuration: Duration(milliseconds: 0),
    animationReverseDuration: Duration(milliseconds: 0),
    preferDirection: PreferDirection.rightTop,
    ignoreContentClick: false,
    onlyOne: true,
    allowClick: true,
    enableSafeArea: true,
    backgroundColor: Color(0x00000000),
    attachedBuilder: builder,
  );
}

class DesktopTabController {
  final state = DesktopTabState().obs;
  final DesktopTabType tabType;

  /// index, key
  Function(int, String)? onRemoved;
  Function(String)? onSelected;
  Future<void> Function()? onCloseWindow;

  DesktopTabController(
      {required this.tabType, this.onRemoved, this.onSelected});

  int get length => state.value.tabs.length;

  void add(TabInfo tab) {
    if (!isDesktop) return;
    final index = state.value.tabs.indexWhere((e) => e.key == tab.key);
    int toIndex;
    if (index >= 0) {
      toIndex = index;
    } else {
      state.update((val) {
        val!.tabs.add(tab);
      });
      state.value.scrollController.itemCount = state.value.tabs.length;
      toIndex = state.value.tabs.length - 1;
      assert(toIndex >= 0);
    }
    try {
      // tabPage has not been initialized, call `onSelected` at the end of initState
      jumpTo(toIndex, callOnSelected: false);
    } catch (e) {
      // call before binding controller will throw
      debugPrint("Failed to jumpTo: $e");
    }
  }

  void remove(int index) {
    if (!isDesktop) return;
    final len = state.value.tabs.length;
    if (index < 0 || index > len - 1) return;
    final key = state.value.tabs[index].key;
    final currentSelected = state.value.selected;
    int toIndex = 0;
    if (index == len - 1) {
      toIndex = max(0, currentSelected - 1);
    } else if (index < len - 1 && index < currentSelected) {
      toIndex = max(0, currentSelected - 1);
    }
    state.value.tabs.removeAt(index);
    state.value.scrollController.itemCount = state.value.tabs.length;
    jumpTo(toIndex);
    onRemoved?.call(index, key);
  }

  /// For addTab, tabPage has not been initialized, set [callOnSelected] to false,
  /// and call [onSelected] at the end of initState
  bool jumpTo(int index, {bool callOnSelected = true}) {
    if (!isDesktop || index < 0) {
      return false;
    }
    state.update((val) {
      if (val != null) {
        val.selected = index;
        Future.delayed(Duration(milliseconds: 100), (() {
          if (val.pageController.hasClients) {
            val.pageController.jumpToPage(index);
          }
          val.scrollController.itemCount = val.tabs.length;
          if (val.scrollController.hasClients &&
              val.scrollController.itemCount > index) {
            val.scrollController
                .scrollToItem(index, center: false, animate: true);
          }
        }));
      }
    });
    if ((isDesktop && (bind.isIncomingOnly() || bind.isOutgoingOnly())) ||
        callOnSelected) {
      if (state.value.tabs.length > index) {
        final key = state.value.tabs[index].key;
        onSelected?.call(key);
      }
    }
    return true;
  }

  bool jumpToByKey(String key, {bool callOnSelected = true}) =>
      jumpTo(state.value.tabs.indexWhere((tab) => tab.key == key),
          callOnSelected: callOnSelected);

  bool jumpToByKeyAndDisplay(String key, int display, {bool isCamera = false}) {
    for (int i = 0; i < state.value.tabs.length; i++) {
      final tab = state.value.tabs[i];
      if (tab.key == key) {
        final ffi = isCamera
            ? (tab.page as ViewCameraPage).ffi
            : (tab.page as RemotePage).ffi;
        if (ffi.ffiModel.pi.currentDisplay == display) {
          return jumpTo(i, callOnSelected: true);
        }
      }
    }
    return false;
  }

  void closeBy(String? key) {
    if (!isDesktop) return;
    assert(onRemoved != null);
    if (key == null) {
      if (state.value.selected < state.value.tabs.length) {
        remove(state.value.selected);
      }
    } else {
      final index = state.value.tabs.indexWhere((tab) => tab.key == key);
      remove(index);
    }
  }

  void clear() {
    state.value.tabs.clear();
    state.refresh();
  }

  Widget? widget(String key) {
    return state.value.tabs.firstWhereOrNull((tab) => tab.key == key)?.page;
  }
}

class TabThemeConf {
  double iconSize;

  TabThemeConf({required this.iconSize});
}

typedef TabBuilder = Widget Function(
    String key, Widget icon, Widget label, TabThemeConf themeConf);
typedef TabMenuBuilder = Widget Function(String key);
typedef LabelGetter = Rx<String> Function(String key);

/// [_lastClickTime], help to handle double click
int _lastClickTime = 0;

class DesktopTab extends StatefulWidget {
  final bool showLogo;
  final bool showTitle;
  final bool showMinimize;
  final bool showMaximize;
  final bool showClose;
  final Widget Function(Widget pageView)? pageViewBuilder;
  // Right click tab menu
  final TabMenuBuilder? tabMenuBuilder;
  final Widget? tail;
  final Future<bool> Function()? onWindowCloseButton;
  final TabBuilder? tabBuilder;
  final LabelGetter? labelGetter;
  final double? maxLabelWidth;
  final Color? selectedTabBackgroundColor;
  final Color? unSelectedTabBackgroundColor;
  final Color? selectedBorderColor;

  final DesktopTabController controller;

  final _scrollDebounce = Debouncer(delay: Duration(milliseconds: 50));

  final RxList<String> invisibleTabKeys = RxList.empty();

  DesktopTab({
    Key? key,
    required this.controller,
    this.showLogo = true,
    this.showTitle = false,
    this.showMinimize = true,
    this.showMaximize = true,
    this.showClose = true,
    this.pageViewBuilder,
    this.tabMenuBuilder,
    this.tail,
    this.onWindowCloseButton,
    this.tabBuilder,
    this.labelGetter,
    this.maxLabelWidth,
    this.selectedTabBackgroundColor,
    this.unSelectedTabBackgroundColor,
    this.selectedBorderColor,
  }) : super(key: key);

  static RxString tablabelGetter(String peerId) {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return RxString(getDesktopTabLabel(peerId, alias));
  }

  @override
  State<DesktopTab> createState() {
    return _DesktopTabState();
  }
}

// ignore: must_be_immutable
class _DesktopTabState extends State<DesktopTab>
    with MultiWindowListener, WindowListener {
  Timer? _macOSCheckRestoreTimer;
  int _macOSCheckRestoreCounter = 0;

  bool get showLogo => widget.showLogo;
  bool get showTitle => widget.showTitle;
  bool get showMinimize => widget.showMinimize;
  bool get showMaximize => widget.showMaximize;
  bool get showClose => widget.showClose;
  Widget Function(Widget pageView)? get pageViewBuilder =>
      widget.pageViewBuilder;
  TabMenuBuilder? get tabMenuBuilder => widget.tabMenuBuilder;
  Widget? get tail => widget.tail;
  Future<bool> Function()? get onWindowCloseButton =>
      widget.onWindowCloseButton;
  TabBuilder? get tabBuilder => widget.tabBuilder;
  LabelGetter? get labelGetter => widget.labelGetter;
  double? get maxLabelWidth => widget.maxLabelWidth;
  Color? get selectedTabBackgroundColor => widget.selectedTabBackgroundColor;
  Color? get unSelectedTabBackgroundColor =>
      widget.unSelectedTabBackgroundColor;
  Color? get selectedBorderColor => widget.selectedBorderColor;
  DesktopTabController get controller => widget.controller;
  RxList<String> get invisibleTabKeys => widget.invisibleTabKeys;
  Debouncer get _scrollDebounce => widget._scrollDebounce;

  Rx<DesktopTabState> get state => controller.state;

  DesktopTabType get tabType => controller.tabType;
  bool get isMainWindow =>
      tabType == DesktopTabType.main ||
      tabType == DesktopTabType.cm ||
      tabType == DesktopTabType.install;

  _DesktopTabState() : super();

  static RxString tablabelGetter(String peerId) {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return RxString(getDesktopTabLabel(peerId, alias));
  }

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.addListener(this);
    windowManager.addListener(this);

    Future.delayed(Duration(milliseconds: 500), () {
      if (isMainWindow) {
        windowManager.isMaximized().then((maximized) {
          if (stateGlobal.isMaximized.value != maximized) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => setState(() => stateGlobal.setMaximized(maximized)));
          }
        });
      } else {
        final wc = WindowController.fromWindowId(kWindowId!);
        wc.isMaximized().then((maximized) {
          debugPrint("isMaximized $maximized");
          if (stateGlobal.isMaximized.value != maximized) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => setState(() => stateGlobal.setMaximized(maximized)));
          }
        });
      }
    });
  }

  @override
  void dispose() {
    DesktopMultiWindow.removeListener(this);
    windowManager.removeListener(this);
    _macOSCheckRestoreTimer?.cancel();
    super.dispose();
  }

  void _setMaximized(bool maximize) {
    stateGlobal.setMaximized(maximize);
    _saveFrame();
    setState(() {});
  }

  @override
  void onWindowFocus() {
    stateGlobal.isFocused.value = true;
  }

  @override
  void onWindowBlur() {
    stateGlobal.isFocused.value = false;
  }

  @override
  void onWindowMinimize() {
    stateGlobal.setMinimized(true);
    stateGlobal.setMaximized(false);
    super.onWindowMinimize();
  }

  @override
  void onWindowMaximize() {
    stateGlobal.setMinimized(false);
    _setMaximized(true);
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    stateGlobal.setMinimized(false);
    _setMaximized(false);
    super.onWindowUnmaximize();
  }

  _saveFrame({bool? flush}) async {
    try {
      if (tabType == DesktopTabType.main) {
        await saveWindowPosition(WindowType.Main, flush: flush);
      } else if (kWindowType != null && kWindowId != null) {
        await saveWindowPosition(kWindowType!,
            windowId: kWindowId, flush: flush);
      }
    } catch (e) {
      debugPrint('Error saving window position: $e');
    }
  }

  // On Linux, GTK destroys the window on a close request unless prevent-close
  // is on. It is off for the cm and install windows, and onActiveWindowChanged()
  // turns it off to quit, so the window can no longer be saved or hidden.
  // https://github.com/rustdesk/rustdesk/issues/16512
  Future<bool> _isLinuxWindowClosed() async =>
      isLinux && isMainWindow && !await windowManager.isPreventClose();

  @override
  void onWindowMoved() {
    _saveFrame();
    super.onWindowMoved();
  }

  @override
  void onWindowResized() {
    _saveFrame();
    super.onWindowResized();
  }

  @override
  void onWindowClose() async {
    mainWindowClose() async => await windowManager.hide();
    notMainWindowClose(WindowController windowController) async {
      if (controller.length != 0) {
        debugPrint("close not empty multiwindow from taskbar");
        if (isWindows) {
          await windowController.show();
          await windowController.focus();
          final res = await onWindowCloseButton?.call() ?? true;
          if (!res) return;
        }
        controller.clear();
      }
      await windowController.hide();
      await rustDeskWinManager
          .call(WindowType.Main, kWindowEventHide, {"id": kWindowId!});
    }

    macOSWindowClose(
      Future<bool> Function() checkFullscreen,
      Future<void> Function() closeFunc,
    ) async {
      _macOSCheckRestoreCounter = 0;
      _macOSCheckRestoreTimer =
          Timer.periodic(Duration(milliseconds: 30), (timer) async {
        _macOSCheckRestoreCounter++;
        if (!await checkFullscreen() || _macOSCheckRestoreCounter >= 30) {
          _macOSCheckRestoreTimer?.cancel();
          _macOSCheckRestoreTimer = null;
          Timer(Duration(milliseconds: 700), () async => await closeFunc());
        }
      });
    }

    if (await _isLinuxWindowClosed()) return;

    await _saveFrame(flush: true);

    // hide window on close
    if (isMainWindow) {
      if (rustDeskWinManager.getActiveWindows().contains(kMainWindowId)) {
        await rustDeskWinManager.unregisterActiveWindow(kMainWindowId);
      }
      if (await _isLinuxWindowClosed()) return;
      // macOS specific workaround, the window is not hiding when in fullscreen.
      if (isMacOS && await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
        await macOSWindowClose(
          () async => await windowManager.isFullScreen(),
          mainWindowClose,
        );
      } else {
        await mainWindowClose();
      }
    } else {
      // it's safe to hide the subwindow
      final controller = WindowController.fromWindowId(kWindowId!);
      if (isMacOS) {
        // onWindowClose() maybe called multiple times because of loopCloseWindow() in remote_tab_page.dart.
        // use ??=  to make sure the value is set on first call.

        if (await onWindowCloseButton?.call() ?? true) {
          if (await controller.isFullScreen()) {
            await controller.setFullscreen(false);
            stateGlobal.setFullscreen(false, procWnd: false);
            await macOSWindowClose(
              () async => await controller.isFullScreen(),
              () async => await notMainWindowClose(controller),
            );
          } else {
            await notMainWindowClose(controller);
          }
        }
      } else {
        await notMainWindowClose(controller);
      }
    }
    super.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Obx(() {
        if (stateGlobal.showTabBar.isTrue &&
            !(kUseCompatibleUiMode && isHideSingleItem())) {
          final showBottomDivider = _showTabBarBottomDivider(tabType);
          return SizedBox(
            height: _kTabBarHeight,
            child: Column(
              children: [
                SizedBox(
                  height:
                      showBottomDivider ? _kTabBarHeight - 1 : _kTabBarHeight,
                  child: _buildBar(),
                ),
                if (showBottomDivider)
                  const Divider(
                    height: 1,
                  ),
              ],
            ),
          );
        } else {
          return Offstage();
        }
      }),
      Expanded(
          child: pageViewBuilder != null
              ? pageViewBuilder!(_buildPageView())
              : _buildPageView())
    ]);
  }

  List<Widget> _tabWidgets = [];
  Widget _buildPageView() {
    final child = Container(
        child: Obx(() => PageView(
            controller: state.value.pageController,
            physics: NeverScrollableScrollPhysics(),
            children: () {
              if (DesktopTabType.cm == tabType) {
                // Fix when adding a new tab still showing closed tabs with the same peer id, which would happen after the DesktopTab was stateful.
                return state.value.tabs.map((tab) {
                  return tab.page;
                }).toList();
              }

              /// to-do refactor, separate connection state and UI state for remote session.
              /// [workaround] PageView children need an immutable list, after it has been passed into PageView
              final tabLen = state.value.tabs.length;
              if (tabLen == _tabWidgets.length) {
                return _tabWidgets;
              } else if (_tabWidgets.isNotEmpty &&
                  tabLen == _tabWidgets.length + 1) {
                /// On add. Use the previous list(pointer) to prevent item's state init twice.
                /// *[_tabWidgets.isNotEmpty] means TabsWindow(remote_tab_page or file_manager_tab_page) opened before, but was hidden. In this case, we have to reload, otherwise the child can't be built.
                _tabWidgets.add(state.value.tabs.last.page);
                return _tabWidgets;
              } else {
                /// On remove or change. Use new list(pointer) to reload list children so that items loading order is normal.
                /// the Widgets in list must enable [AutomaticKeepAliveClientMixin]
                final newList = state.value.tabs.map((v) => v.page).toList();
                _tabWidgets = newList;
                return newList;
              }
            }())));
    if (tabType == DesktopTabType.remoteScreen) {
      return Container(color: kColorCanvas, child: child);
    } else {
      return child;
    }
  }

  /// Check whether to show ListView
  ///
  /// Conditions:
  /// - hide single item when only has one item (home) on [DesktopTabPage].
  bool isHideSingleItem() {
    return state.value.tabs.length == 1 &&
        (controller.tabType == DesktopTabType.main ||
            controller.tabType == DesktopTabType.install);
  }

  Widget _buildBar() {
    final isIncomingHomePage = bind.isIncomingOnly() && isInHomePage();
    return Row(
      children: [
        Expanded(
            child: GestureDetector(
                // custom double tap handler
                onTap: !isIncomingHomePage && showMaximize
                    ? () {
                        final current = DateTime.now().millisecondsSinceEpoch;
                        final elapsed = current - _lastClickTime;
                        _lastClickTime = current;
                        if (elapsed < bind.getDoubleClickTime()) {
                          // onDoubleTap
                          toggleMaximize(isMainWindow)
                              .then((value) => stateGlobal.setMaximized(value));
                        }
                      }
                    : (isIncomingHomePage ? () {} : null), // Keep tap recognizer for Windows touch.
                onPanStart: (_) => startDragging(isMainWindow),
                onPanCancel: () {
                  // We want to disable dragging of the tab area in the tab bar.
                  // Disable dragging is needed because macOS handles dragging by default.
                  if (isMacOS) {
                    setMovable(isMainWindow, false);
                  }
                },
                onPanEnd: (_) {
                  if (isMacOS) {
                    setMovable(isMainWindow, false);
                  }
                },
                child: Row(
                  children: [
                    Offstage(
                        offstage: !isMacOS,
                        child: const SizedBox(
                          width: 78,
                        )),
                    Offstage(
                      offstage: kUseCompatibleUiMode || isMacOS,
                      child: Row(children: [
                        Offstage(
                          offstage: !showLogo,
                          child: loadIcon(20),
                        ),
                        Offstage(
                            offstage: !showTitle,
                            child: const Text(
                              "Quantix Remoto",
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700),
                            ).marginOnly(left: 2))
                      ]).marginOnly(
                        left: 5,
                        right: 10,
                      ),
                    ),
                    Expanded(
                        child: Listener(
                            // handle mouse wheel
                            onPointerSignal: (e) {
                              if (e is PointerScrollEvent) {
                                final sc =
                                    controller.state.value.scrollController;
                                if (!sc.canScroll) return;
                                _scrollDebounce.call(() {
                                  double adjust = 2.5;
                                  sc.animateTo(
                                      sc.offset + e.scrollDelta.dy * adjust,
                                      duration: Duration(milliseconds: 200),
                                      curve: Curves.ease);
                                });
                              }
                            },
                            child: _ListView(
                              controller: controller,
                              invisibleTabKeys: invisibleTabKeys,
                              tabBuilder: tabBuilder,
                              tabMenuBuilder: tabMenuBuilder,
                              labelGetter: labelGetter,
                              maxLabelWidth: maxLabelWidth,
                              selectedTabBackgroundColor:
                                  selectedTabBackgroundColor,
                              unSelectedTabBackgroundColor:
                                  unSelectedTabBackgroundColor,
                              selectedBorderColor: selectedBorderColor,
                            ))),
                  ],
                ))),
        // hide simulated action buttons when we in compatible ui mode, because of reusing system title bar.
        WindowActionPanel(
          isMainWindow: isMainWindow,
          state: state,
          tabController: controller,
          invisibleTabKeys: invisibleTabKeys,
          tail: tail,
          showMinimize: showMinimize,
          showMaximize: showMaximize,
          showClose: showClose,
          onClose: onWindowCloseButton,
          labelGetter: labelGetter,
        ).paddingOnly(left: 10)
      ],
    );
  }
}

class WindowActionPanel extends StatefulWidget {
  final bool isMainWindow;
  final Rx<DesktopTabState> state;
  final DesktopTabController tabController;

  final bool showMinimize;
  final bool showMaximize;
  final bool showClose;
  final Widget? tail;
  final Future<bool> Function()? onClose;

  final RxList<String> invisibleTabKeys;
  final LabelGetter? labelGetter;

  const WindowActionPanel(
      {Key? key,
      required this.isMainWindow,
      required this.state,
      required this.tabController,
      required this.invisibleTabKeys,
      this.tail,
      this.showMinimize = true,
      this.showMaximize = true,
      this.showClose = true,
      this.onClose,
      this.labelGetter})
      : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return WindowActionPanelState();
  }
}

class WindowActionPanelState extends State<WindowActionPanel> {
  bool showTabDowndown() {
    return widget.tabController.state.value.tabs.length > 1 &&
        (widget.tabController.tabType == DesktopTabType.remoteScreen ||
            widget.tabController.tabType == DesktopTabType.fileTransfer ||
            widget.tabController.tabType == DesktopTabType.viewCamera ||
            widget.tabController.tabType == DesktopTabType.portForward ||
            widget.tabController.tabType == DesktopTabType.cm);
  }

  List<String> existingInvisibleTab() {
    return widget.invisibleTabKeys
        .where((key) =>
            widget.tabController.state.value.tabs.any((tab) => tab.key == key))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Obx(() {
          if (showTabDowndown() && existingInvisibleTab().isNotEmpty) {
            return _TabDropDownButton(
                controller: widget.tabController,
                labelGetter: widget.labelGetter,
                tabkeys: existingInvisibleTab());
          } else {
            return Offstage();
          }
        }),
        if (widget.isMainWindow) const _QuantixTopBarActions(),
        if (widget.tail != null) widget.tail!,
        if (!kUseCompatibleUiMode)
          Row(
            children: [
              if (widget.showMinimize && !isMacOS)
                ActionIcon(
                  message: 'Minimize',
                  icon: IconFont.min,
                  onTap: () {
                    if (widget.isMainWindow) {
                      windowManager.minimize();
                    } else {
                      WindowController.fromWindowId(kWindowId!).minimize();
                    }
                  },
                  isClose: false,
                ),
              if (widget.showMaximize && !isMacOS)
                Obx(() => ActionIcon(
                      message: stateGlobal.isMaximized.isTrue
                          ? 'Restore'
                          : 'Maximize',
                      icon: stateGlobal.isMaximized.isTrue
                          ? IconFont.restore
                          : IconFont.max,
                      onTap: bind.isIncomingOnly() && isInHomePage()
                          ? null
                          : _toggleMaximize,
                      isClose: false,
                    )),
              if (widget.showClose && !isMacOS)
                ActionIcon(
                  message: 'Close',
                  icon: IconFont.close,
                  onTap: () async {
                    final res = await widget.onClose?.call() ?? true;
                    if (res) {
                      // hide for all window
                      // note: the main window can be restored by tray icon
                      Future.delayed(Duration.zero, () async {
                        if (widget.isMainWindow) {
                          await windowManager.close();
                        } else {
                          await WindowController.fromWindowId(kWindowId!)
                              .close();
                        }
                      });
                    }
                  },
                  isClose: true,
                )
            ],
          ),
      ],
    );
  }

  void _toggleMaximize() {
    toggleMaximize(widget.isMainWindow).then((maximize) {
      // update state for sub window, wc.unmaximize/maximize() will not invoke onWindowMaximize/Unmaximize
      stateGlobal.setMaximized(maximize);
    });
  }
}

void startDragging(bool isMainWindow) {
  if (isMainWindow) {
    windowManager.startDragging();
  } else {
    WindowController.fromWindowId(kWindowId!).startDragging();
  }
}

void setMovable(bool isMainWindow, bool movable) {
  if (isMainWindow) {
    windowManager.setMovable(movable);
  } else {
    WindowController.fromWindowId(kWindowId!).setMovable(movable);
  }
}

/// return true -> window will be maximize
/// return false -> window will be unmaximize
Future<bool> toggleMaximize(bool isMainWindow) async {
  if (isMainWindow) {
    if (await windowManager.isMaximized()) {
      windowManager.unmaximize();
      return false;
    } else {
      windowManager.maximize();
      return true;
    }
  } else {
    final wc = WindowController.fromWindowId(kWindowId!);
    if (await wc.isMaximized()) {
      wc.unmaximize();
      return false;
    } else {
      wc.maximize();
      return true;
    }
  }
}

Future<bool> closeConfirmDialog() async {
  var confirm = true;
  final res = await gFFI.dialogManager.show<bool>((setState, close, context) {
    submit() {
      String value = bool2option(kOptionEnableConfirmClosingTabs, confirm);
      bind.mainSetLocalOption(
          key: kOptionEnableConfirmClosingTabs, value: value);
      close(true);
    }

    return CustomAlertDialog(
      title: Row(children: [
        const Icon(Icons.warning_amber_sharp,
            color: Colors.redAccent, size: 28),
        const SizedBox(width: 10),
        Text(translate("Warning")),
      ]),
      content: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate("Disconnect all devices?")),
            CheckboxListTile(
              contentPadding: const EdgeInsets.all(0),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                translate("Confirm before closing multiple tabs"),
              ),
              value: confirm,
              onChanged: (v) {
                if (v == null) return;
                setState(() => confirm = v);
              },
            )
          ]),
      // confirm checkbox
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
  return res == true;
}

class _ListView extends StatelessWidget {
  final DesktopTabController controller;
  final RxList<String> invisibleTabKeys;

  final TabBuilder? tabBuilder;
  final TabMenuBuilder? tabMenuBuilder;
  final LabelGetter? labelGetter;
  final double? maxLabelWidth;
  final Color? selectedTabBackgroundColor;
  final Color? selectedBorderColor;
  final Color? unSelectedTabBackgroundColor;

  Rx<DesktopTabState> get state => controller.state;

  _ListView({
    required this.controller,
    required this.invisibleTabKeys,
    this.tabBuilder,
    this.tabMenuBuilder,
    this.labelGetter,
    this.maxLabelWidth,
    this.selectedTabBackgroundColor,
    this.unSelectedTabBackgroundColor,
    this.selectedBorderColor,
  });

  /// Check whether to show ListView
  ///
  /// Conditions:
  /// - hide single item when only has one item (home) on [DesktopTabPage].
  bool isHideSingleItem() {
    return state.value.tabs.length == 1 &&
            controller.tabType == DesktopTabType.main ||
        controller.tabType == DesktopTabType.install;
  }

  onVisibilityChanged(VisibilityInfo info) {
    final key = (info.key as ValueKey).value;
    if (info.visibleFraction < 0.75) {
      if (!invisibleTabKeys.contains(key)) {
        invisibleTabKeys.add(key);
      }
      invisibleTabKeys.removeWhere((key) =>
          controller.state.value.tabs.where((e) => e.key == key).isEmpty);
    } else {
      invisibleTabKeys.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() => ListView(
        controller: state.value.scrollController,
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        children: isHideSingleItem()
            ? List.empty()
            : state.value.tabs.asMap().entries.map((e) {
                final index = e.key;
                final tab = e.value;
                final label = labelGetter == null
                    ? Rx<String>(tab.label)
                    : labelGetter!(tab.label);
                final child = VisibilityDetector(
                  key: ValueKey(tab.key),
                  onVisibilityChanged: onVisibilityChanged,
                  child: _Tab(
                    key: ValueKey(tab.key),
                    index: index,
                    tabInfoKey: tab.key,
                    label: label,
                    tabType: controller.tabType,
                    selectedIcon: tab.selectedIcon,
                    unselectedIcon: tab.unselectedIcon,
                    closable: tab.closable,
                    selected: state.value.selected,
                    onClose: () {
                      if (tab.onTabCloseButton != null) {
                        tab.onTabCloseButton!();
                      } else {
                        controller.remove(index);
                      }
                    },
                    onTap: () {
                      controller.jumpTo(index);
                      tab.onTap?.call();
                    },
                    tabBuilder: tabBuilder,
                    tabMenuBuilder: tabMenuBuilder,
                    maxLabelWidth: maxLabelWidth,
                    selectedTabBackgroundColor: selectedTabBackgroundColor ??
                        MyTheme.tabbar(context).selectedTabBackgroundColor,
                    unSelectedTabBackgroundColor: unSelectedTabBackgroundColor,
                    selectedBorderColor: selectedBorderColor,
                  ),
                );
                return GestureDetector(
                  onPanStart: (e) {},
                  child: child,
                );
              }).toList()));
  }
}

class _Tab extends StatefulWidget {
  final int index;
  final String tabInfoKey;
  final Rx<String> label;
  final DesktopTabType tabType;
  final IconData? selectedIcon;
  final IconData? unselectedIcon;
  final bool closable;
  final int selected;
  final Function() onClose;
  final Function() onTap;
  final TabBuilder? tabBuilder;
  final TabMenuBuilder? tabMenuBuilder;
  final double? maxLabelWidth;
  final Color? selectedTabBackgroundColor;
  final Color? unSelectedTabBackgroundColor;
  final Color? selectedBorderColor;

  const _Tab({
    Key? key,
    required this.index,
    required this.tabInfoKey,
    required this.label,
    required this.tabType,
    this.selectedIcon,
    this.unselectedIcon,
    this.tabBuilder,
    this.tabMenuBuilder,
    required this.closable,
    required this.selected,
    required this.onClose,
    required this.onTap,
    this.maxLabelWidth,
    this.selectedTabBackgroundColor,
    this.unSelectedTabBackgroundColor,
    this.selectedBorderColor,
  }) : super(key: key);

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with RestorationMixin {
  final RestorableBool restoreHover = RestorableBool(false);

  Widget _buildTabContent() {
    bool showIcon =
        widget.selectedIcon != null && widget.unselectedIcon != null;
    bool isSelected = widget.index == widget.selected;

    final icon = Offstage(
        offstage: !showIcon,
        child: Icon(
          isSelected ? widget.selectedIcon : widget.unselectedIcon,
          size: _kIconSize,
          color: isSelected
              ? MyTheme.tabbar(context).selectedTabIconColor
              : MyTheme.tabbar(context).unSelectedTabIconColor,
        ).paddingOnly(right: 5));
    final labelWidget = Obx(() {
      return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxLabelWidth ?? 200),
          child: Tooltip(
            message:
                widget.tabType == DesktopTabType.main ? '' : widget.label.value,
            child: Text(
              widget.tabType == DesktopTabType.main
                  ? translate(widget.label.value)
                  : widget.label.value,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: isSelected
                      ? MyTheme.tabbar(context).selectedTextColor
                      : MyTheme.tabbar(context).unSelectedTextColor),
              overflow: TextOverflow.ellipsis,
            ),
          ));
    });

    Widget getWidgetWithBuilder() {
      if (widget.tabBuilder == null) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            labelWidget,
          ],
        );
      } else {
        return widget.tabBuilder!(
          widget.tabInfoKey,
          icon,
          labelWidget,
          TabThemeConf(iconSize: _kIconSize),
        );
      }
    }

    return Listener(
      onPointerDown: (e) {
        if (e.kind != ui.PointerDeviceKind.mouse) {
          return;
        }
        if (e.buttons == 2) {
          if (widget.tabMenuBuilder != null) {
            showRightMenu(
              (cacel) {
                return widget.tabMenuBuilder!(widget.tabInfoKey);
              },
              target: e.position,
            );
          }
        }
      },
      child: getWidgetWithBuilder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isSelected = widget.index == widget.selected;
    bool showDivider =
        widget.index != widget.selected - 1 && widget.index != widget.selected;
    RxBool hover = restoreHover.value.obs;
    return Ink(
      child: InkWell(
        onHover: (value) {
          hover.value = value;
          restoreHover.value = value;
        },
        onTap: () => widget.onTap(),
        child: Container(
            decoration: isSelected && widget.selectedBorderColor != null
                ? BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: widget.selectedBorderColor!,
                        width: 1,
                      ),
                    ),
                  )
                : null,
            child: Container(
              color: isSelected
                  ? widget.selectedTabBackgroundColor
                  : widget.unSelectedTabBackgroundColor,
              child: Row(
                children: [
                  SizedBox(
                      // _kTabBarHeight also displays normally
                      height: _showTabBarBottomDivider(widget.tabType)
                          ? _kTabBarHeight - 1
                          : _kTabBarHeight,
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _buildTabContent(),
                            Obx((() => _CloseButton(
                                  visible: hover.value && widget.closable,
                                  tabSelected: isSelected,
                                  onClose: () => widget.onClose(),
                                )))
                          ])).paddingOnly(left: 10, right: 5),
                  Offstage(
                    offstage: !showDivider,
                    child: VerticalDivider(
                      width: 1,
                      indent: _kDividerIndent,
                      endIndent: _kDividerIndent,
                      color: MyTheme.tabbar(context).dividerColor,
                    ),
                  )
                ],
              ),
            )),
      ),
    );
  }

  @override
  String? get restorationId => "_Tab${widget.label.value}";

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(restoreHover, 'restoreHover');
  }
}

class _CloseButton extends StatelessWidget {
  final bool visible;
  final bool tabSelected;
  final Function onClose;

  const _CloseButton({
    Key? key,
    required this.visible,
    required this.tabSelected,
    required this.onClose,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
            width: _kIconSize,
            child: () {
              if (visible) {
                return InkWell(
                  hoverColor: MyTheme.tabbar(context).closeHoverColor,
                  customBorder: const CircleBorder(),
                  onTap: () => onClose(),
                  child: Icon(
                    Icons.close,
                    size: _kIconSize,
                    color: tabSelected
                        ? MyTheme.tabbar(context).selectedIconColor
                        : MyTheme.tabbar(context).unSelectedIconColor,
                  ),
                );
              } else {
                return Offstage();
              }
            }())
        .paddingOnly(left: 10);
  }
}

class ActionIcon extends StatefulWidget {
  final String? message;
  final IconData icon;
  final GestureTapCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final bool isClose;
  final double iconSize;
  final double boxSize;

  const ActionIcon(
      {Key? key,
      this.message,
      required this.icon,
      this.onTap,
      this.onTapDown,
      this.isClose = false,
      this.iconSize = _kActionIconSize,
      this.boxSize = _kTabBarHeight - 1})
      : super(key: key);

  @override
  State<ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<ActionIcon> {
  final hover = false.obs;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.message != null ? translate(widget.message!) : "",
      waitDuration: const Duration(seconds: 1),
      child: InkWell(
        hoverColor: widget.isClose
            ? const Color.fromARGB(255, 196, 43, 28)
            : MyTheme.tabbar(context).hoverColor,
        onHover: (value) => hover.value = value,
        onTap: widget.onTap,
        onTapDown: widget.onTapDown,
        child: SizedBox(
          height: widget.boxSize,
          width: widget.boxSize,
          child: widget.onTap == null
              ? Icon(
                  widget.icon,
                  color: Colors.grey,
                  size: widget.iconSize,
                )
              : Obx(
                  () => Icon(
                    widget.icon,
                    color: hover.value && widget.isClose
                        ? Colors.white
                        : MyTheme.tabbar(context).unSelectedIconColor,
                    size: widget.iconSize,
                  ),
                ),
        ),
      ),
    );
  }
}

class AddButton extends StatelessWidget {
  const AddButton({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ActionIcon(
        message: 'New Connection',
        icon: IconFont.add,
        onTap: () => rustDeskWinManager.call(
            WindowType.Main, kWindowMainWindowOnTop, ""),
        isClose: false);
  }
}

class _TabDropDownButton extends StatefulWidget {
  final DesktopTabController controller;
  final List<String> tabkeys;
  final LabelGetter? labelGetter;

  const _TabDropDownButton(
      {required this.controller, required this.tabkeys, this.labelGetter});

  @override
  State<_TabDropDownButton> createState() => _TabDropDownButtonState();
}

class _TabDropDownButtonState extends State<_TabDropDownButton> {
  var position = RelativeRect.fromLTRB(0, 0, 0, 0);

  @override
  Widget build(BuildContext context) {
    List<String> sortedKeys = widget.controller.state.value.tabs
        .where((e) => widget.tabkeys.contains(e.key))
        .map((e) => e.key)
        .toList();
    return ActionIcon(
      onTapDown: (details) {
        final x = details.globalPosition.dx;
        final y = details.globalPosition.dy;
        position = RelativeRect.fromLTRB(x, y, x, y);
      },
      icon: Icons.arrow_drop_down,
      onTap: () {
        showMenu(
          context: context,
          position: position,
          items: sortedKeys.map((e) {
            var label = e;
            final tabInfo = widget.controller.state.value.tabs
                .firstWhereOrNull((element) => element.key == e);
            if (tabInfo != null) {
              label = tabInfo.label;
            }
            if (widget.labelGetter != null) {
              label = widget.labelGetter!(e).value;
            }
            var index = widget.controller.state.value.tabs
                .indexWhere((t) => t.key == e);
            label = '${index + 1}. $label';
            final menuHover = false.obs;
            final btnHover = false.obs;
            return PopupMenuItem<String>(
              value: e,
              height: 32,
              onTap: () {
                widget.controller.jumpToByKey(e);
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              child: MouseRegion(
                onHover: (event) => setState(() => menuHover.value = true),
                onExit: (event) => setState(() => menuHover.value = false),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(child: Text(label)),
                    ),
                    Obx(
                      () {
                        if (tabInfo?.onTabCloseButton != null &&
                            menuHover.value) {
                          return InkWell(
                              onTap: () {
                                tabInfo?.onTabCloseButton?.call();
                                if (Navigator.of(context).canPop()) {
                                  Navigator.of(context).pop();
                                }
                              },
                              child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onHover: (event) =>
                                      setState(() => btnHover.value = true),
                                  onExit: (event) =>
                                      setState(() => btnHover.value = false),
                                  child: Icon(Icons.close,
                                      color:
                                          btnHover.value ? Colors.red : null)));
                        } else {
                          return Offstage();
                        }
                      },
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

bool _showTabBarBottomDivider(DesktopTabType tabType) {
  return tabType == DesktopTabType.main || tabType == DesktopTabType.install;
}

class TabbarTheme extends ThemeExtension<TabbarTheme> {
  final Color? selectedTabIconColor;
  final Color? unSelectedTabIconColor;
  final Color? selectedTextColor;
  final Color? unSelectedTextColor;
  final Color? selectedIconColor;
  final Color? unSelectedIconColor;
  final Color? dividerColor;
  final Color? hoverColor;
  final Color? closeHoverColor;
  final Color? selectedTabBackgroundColor;

  const TabbarTheme(
      {required this.selectedTabIconColor,
      required this.unSelectedTabIconColor,
      required this.selectedTextColor,
      required this.unSelectedTextColor,
      required this.selectedIconColor,
      required this.unSelectedIconColor,
      required this.dividerColor,
      required this.hoverColor,
      required this.closeHoverColor,
      required this.selectedTabBackgroundColor});

  static const light = TabbarTheme(
      selectedTabIconColor: MyTheme.accent,
      unSelectedTabIconColor: Color.fromARGB(255, 162, 203, 241),
      selectedTextColor: Colors.black,
      unSelectedTextColor: Color.fromARGB(255, 112, 112, 112),
      selectedIconColor: Color.fromARGB(255, 26, 26, 26),
      unSelectedIconColor: Color.fromARGB(255, 96, 96, 96),
      dividerColor: Color.fromARGB(255, 238, 238, 238),
      hoverColor: Colors.white54,
      closeHoverColor: Colors.white,
      selectedTabBackgroundColor: Colors.white54);

  static const dark = TabbarTheme(
      selectedTabIconColor: MyTheme.accent,
      unSelectedTabIconColor: Color.fromARGB(255, 30, 65, 98),
      selectedTextColor: Colors.white,
      unSelectedTextColor: Color.fromARGB(255, 192, 192, 192),
      selectedIconColor: Color.fromARGB(255, 192, 192, 192),
      unSelectedIconColor: Color.fromARGB(255, 255, 255, 255),
      dividerColor: Color.fromARGB(255, 64, 64, 64),
      hoverColor: Colors.black26,
      closeHoverColor: Colors.black,
      selectedTabBackgroundColor: Colors.black26);

  @override
  ThemeExtension<TabbarTheme> copyWith({
    Color? selectedTabIconColor,
    Color? unSelectedTabIconColor,
    Color? selectedTextColor,
    Color? unSelectedTextColor,
    Color? selectedIconColor,
    Color? unSelectedIconColor,
    Color? dividerColor,
    Color? hoverColor,
    Color? closeHoverColor,
    Color? selectedTabBackgroundColor,
  }) {
    return TabbarTheme(
      selectedTabIconColor: selectedTabIconColor ?? this.selectedTabIconColor,
      unSelectedTabIconColor:
          unSelectedTabIconColor ?? this.unSelectedTabIconColor,
      selectedTextColor: selectedTextColor ?? this.selectedTextColor,
      unSelectedTextColor: unSelectedTextColor ?? this.unSelectedTextColor,
      selectedIconColor: selectedIconColor ?? this.selectedIconColor,
      unSelectedIconColor: unSelectedIconColor ?? this.unSelectedIconColor,
      dividerColor: dividerColor ?? this.dividerColor,
      hoverColor: hoverColor ?? this.hoverColor,
      closeHoverColor: closeHoverColor ?? this.closeHoverColor,
      selectedTabBackgroundColor:
          selectedTabBackgroundColor ?? this.selectedTabBackgroundColor,
    );
  }

  @override
  ThemeExtension<TabbarTheme> lerp(
      ThemeExtension<TabbarTheme>? other, double t) {
    if (other is! TabbarTheme) {
      return this;
    }
    return TabbarTheme(
      selectedTabIconColor:
          Color.lerp(selectedTabIconColor, other.selectedTabIconColor, t),
      unSelectedTabIconColor:
          Color.lerp(unSelectedTabIconColor, other.unSelectedTabIconColor, t),
      selectedTextColor:
          Color.lerp(selectedTextColor, other.selectedTextColor, t),
      unSelectedTextColor:
          Color.lerp(unSelectedTextColor, other.unSelectedTextColor, t),
      selectedIconColor:
          Color.lerp(selectedIconColor, other.selectedIconColor, t),
      unSelectedIconColor:
          Color.lerp(unSelectedIconColor, other.unSelectedIconColor, t),
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t),
      hoverColor: Color.lerp(hoverColor, other.hoverColor, t),
      closeHoverColor: Color.lerp(closeHoverColor, other.closeHoverColor, t),
      selectedTabBackgroundColor: Color.lerp(
          selectedTabBackgroundColor, other.selectedTabBackgroundColor, t),
    );
  }

  static color(BuildContext context) {
    return Theme.of(context).extension<ColorThemeExtension>()!;
  }
}


class _QuantixTopBarActions extends StatefulWidget {
  const _QuantixTopBarActions({Key? key}) : super(key: key);

  @override
  State<_QuantixTopBarActions> createState() => _QuantixTopBarActionsState();
}

class _QuantixTopBarActionsState extends State<_QuantixTopBarActions> {
  static const List<Map<String, String>> _langs = [
    {'key': 'pt-br', 'short': 'PT', 'label': 'Português (Brasil)'},
    {'key': 'en', 'short': 'EN', 'label': 'English'},
    {'key': 'es', 'short': 'ES', 'label': 'Español'},
    {'key': 'fr', 'short': 'FR', 'label': 'Français'},
    {'key': 'de', 'short': 'DE', 'label': 'Deutsch'},
  ];

  bool _checkingUpdate = false;

  String _activeLangCode() {
    String raw = '';
    try {
      raw = bind.mainGetLocalOption(key: kCommConfKeyLang).trim().toLowerCase();
    } catch (_) {}
    if (raw.isEmpty) {
      raw = localeName.toLowerCase();
    }
    if (raw.startsWith('pt')) return 'pt';
    if (raw.startsWith('es')) return 'es';
    if (raw.startsWith('fr')) return 'fr';
    if (raw.startsWith('de')) return 'de';
    return 'en';
  }

  String _activeShortLabel() {
    switch (_activeLangCode()) {
      case 'pt':
        return 'PT';
      case 'es':
        return 'ES';
      case 'fr':
        return 'FR';
      case 'de':
        return 'DE';
      default:
        return 'EN';
    }
  }

  Map<String, String> _tr(String lang) {
    switch (lang) {
      case 'pt':
        return {
          'fbTip': 'Sugestões & Bugs',
          'fbTitle': 'Sugestões, Dúvidas & Bugs',
          'fbCat': 'Categoria',
          'fbCatSug': 'Sugestão de Melhoria',
          'fbCatFeat': 'Nova Funcionalidade',
          'fbCatBug': 'Relatar Bug / Erro',
          'fbCatDoubt': 'Dúvida',
          'fbCatCrit': 'Crítica',
          'fbSubj': 'Assunto (opcional)',
          'fbEmail': 'Seu e-mail para retorno',
          'fbMsg': 'Descreva sua mensagem *',
          'fbSend': 'Enviar Feedback',
          'fbCancel': 'Cancelar',
          'fbMinErr': 'Digite pelo menos 5 caracteres na mensagem.',
          'fbOk': 'Feedback enviado para a equipe Quantix! Obrigado.',
          'fbErr': 'Não foi possível enviar o feedback.',
          'updTip': 'Verificar Atualizações',
          'updTitle': 'Atualização do Quantix Remote',
          'updLatest': 'Você já está utilizando a versão mais recente.',
          'updNew': 'Nova versão disponível!',
          'updCur': 'Versão atual',
          'updAvail': 'Versão no servidor',
          'updDownload': 'Baixar Nova Versão (.EXE)',
          'updClose': 'Fechar',
          'updFail': 'Não foi possível consultar o servidor de atualizações agora.',
          'langTip': 'Idioma (PT / EN / ES / FR / DE)',
          'themeTip': 'Alternar Tema Claro / Escuro',
        };
      case 'es':
        return {
          'fbTip': 'Sugerencias y Bugs',
          'fbTitle': 'Sugerencias, Dudas y Bugs',
          'fbCat': 'Categoría',
          'fbCatSug': 'Sugerencia de Mejora',
          'fbCatFeat': 'Nueva Funcionalidad',
          'fbCatBug': 'Reportar Bug / Error',
          'fbCatDoubt': 'Duda',
          'fbCatCrit': 'Crítica',
          'fbSubj': 'Asunto (opcional)',
          'fbEmail': 'Tu correo de contacto',
          'fbMsg': 'Describe tu mensaje *',
          'fbSend': 'Enviar Feedback',
          'fbCancel': 'Cancelar',
          'fbMinErr': 'Escribe al menos 5 caracteres en el mensaje.',
          'fbOk': '¡Feedback enviado al equipo Quantix! Gracias.',
          'fbErr': 'No se pudo enviar el feedback.',
          'updTip': 'Buscar Actualizaciones',
          'updTitle': 'Actualización de Quantix Remote',
          'updLatest': 'Ya estás usando la versión más reciente.',
          'updNew': '¡Nueva versión disponible!',
          'updCur': 'Versión actual',
          'updAvail': 'Versión en el servidor',
          'updDownload': 'Descargar Nueva Versión (.EXE)',
          'updClose': 'Cerrar',
          'updFail': 'No se pudo consultar el servidor de actualizaciones.',
          'langTip': 'Idioma (PT / EN / ES / FR / DE)',
          'themeTip': 'Cambiar Tema Claro / Oscuro',
        };
      case 'fr':
        return {
          'fbTip': 'Suggestions & Bugs',
          'fbTitle': 'Suggestions, Questions & Bugs',
          'fbCat': 'Catégorie',
          'fbCatSug': 'Suggestion d’amélioration',
          'fbCatFeat': 'Nouvelle fonctionnalité',
          'fbCatBug': 'Signaler un bug / erreur',
          'fbCatDoubt': 'Question',
          'fbCatCrit': 'Critique',
          'fbSubj': 'Sujet (optionnel)',
          'fbEmail': 'Votre e-mail de contact',
          'fbMsg': 'Décrivez votre message *',
          'fbSend': 'Envoyer',
          'fbCancel': 'Annuler',
          'fbMinErr': 'Veuillez saisir au moins 5 caractères.',
          'fbOk': 'Feedback envoyé à l’équipe Quantix ! Merci.',
          'fbErr': 'Impossible d’envoyer le feedback.',
          'updTip': 'Vérifier les mises à jour',
          'updTitle': 'Mise à jour Quantix Remote',
          'updLatest': 'Vous utilisez déjà la dernière version.',
          'updNew': 'Nouvelle version disponible !',
          'updCur': 'Version actuelle',
          'updAvail': 'Version sur le serveur',
          'updDownload': 'Télécharger (.EXE)',
          'updClose': 'Fermer',
          'updFail': 'Impossible de joindre le serveur de mises à jour.',
          'langTip': 'Langue (PT / EN / ES / FR / DE)',
          'themeTip': 'Basculer Thème Clair / Sombre',
        };
      case 'de':
        return {
          'fbTip': 'Vorschläge & Bugs',
          'fbTitle': 'Vorschläge, Fragen & Bugs',
          'fbCat': 'Kategorie',
          'fbCatSug': 'Verbesserungsvorschlag',
          'fbCatFeat': 'Neue Funktion',
          'fbCatBug': 'Bug / Fehler melden',
          'fbCatDoubt': 'Frage',
          'fbCatCrit': 'Kritik',
          'fbSubj': 'Betreff (optional)',
          'fbEmail': 'Ihre E-Mail-Adresse',
          'fbMsg': 'Nachricht eingeben *',
          'fbSend': 'Senden',
          'fbCancel': 'Abbrechen',
          'fbMinErr': 'Bitte geben Sie mindestens 5 Zeichen ein.',
          'fbOk': 'Feedback an das Quantix-Team gesendet! Vielen Dank.',
          'fbErr': 'Feedback konnte nicht gesendet werden.',
          'updTip': 'Nach Updates suchen',
          'updTitle': 'Quantix Remote Update',
          'updLatest': 'Sie verwenden bereits die neueste Version.',
          'updNew': 'Neue Version verfügbar!',
          'updCur': 'Aktuelle Version',
          'updAvail': 'Server-Version',
          'updDownload': 'Neue Version herunterladen (.EXE)',
          'updClose': 'Schließen',
          'updFail': 'Update-Server derzeit nicht erreichbar.',
          'langTip': 'Sprache (PT / EN / ES / FR / DE)',
          'themeTip': 'Helles / Dunkles Design wechseln',
        };
      default:
        return {
          'fbTip': 'Feedback & Bugs',
          'fbTitle': 'Suggestions, Questions & Bugs',
          'fbCat': 'Category',
          'fbCatSug': 'Improvement Suggestion',
          'fbCatFeat': 'New Feature Request',
          'fbCatBug': 'Report Bug / Issue',
          'fbCatDoubt': 'Question',
          'fbCatCrit': 'Criticism',
          'fbSubj': 'Subject (optional)',
          'fbEmail': 'Your reply email',
          'fbMsg': 'Describe your message *',
          'fbSend': 'Send Feedback',
          'fbCancel': 'Cancel',
          'fbMinErr': 'Please enter at least 5 characters.',
          'fbOk': 'Feedback sent to the Quantix team! Thank you.',
          'fbErr': 'Failed to send feedback.',
          'updTip': 'Check for Updates',
          'updTitle': 'Quantix Remote Update',
          'updLatest': 'You are already running the latest version.',
          'updNew': 'A new version is available!',
          'updCur': 'Current version',
          'updAvail': 'Server version',
          'updDownload': 'Download New Version (.EXE)',
          'updClose': 'Close',
          'updFail': 'Unable to check update server right now.',
          'langTip': 'Language (PT / EN / ES / FR / DE)',
          'themeTip': 'Toggle Light / Dark Theme',
        };
    }
  }

  void _openFeedbackDialog() {
    final lang = _activeLangCode();
    final t = _tr(lang);
    String category = 'suggestion';
    String statusErr = '';
    bool sending = false;
    final subjCtrl = TextEditingController();
    final defaultUser = gFFI.userModel.userName.value.trim();
    final emailCtrl = TextEditingController(
      text: defaultUser.contains('@') ? defaultUser : '',
    );
    final msgCtrl = TextEditingController();

    gFFI.dialogManager.show((setState, close, context) {
      Future<void> submit() async {
        final msg = msgCtrl.text.trim();
        if (msg.length < 5) {
          setState(() => statusErr = t['fbMinErr']!);
          return;
        }
        setState(() {
          sending = true;
          statusErr = '';
        });
        try {
          final machineId = gFFI.serverModel.serverId.text.trim();
          final res = await http
              .post(
                Uri.parse(
                    'https://www.2048quantix.com/portal/api.php?action=submit_feedback'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'product': 'remote',
                  'source': 'desktop',
                  'category': category,
                  'subject': subjCtrl.text.trim(),
                  'user_email': emailCtrl.text.trim(),
                  'user_name': gFFI.userModel.displayNameOrUserName.trim(),
                  'machine_id': machineId,
                  'app_version': version.isNotEmpty ? version : '1.5.2',
                  'lang': lang,
                  'message': msg,
                }),
              )
              .timeout(const Duration(seconds: 10));
          final data = jsonDecode(res.body);
          if (res.statusCode == 200 && data is Map && data['ok'] == true) {
            close();
            showToast(t['fbOk']!);
          } else {
            final errMsg = (data is Map && data['error'] != null)
                ? data['error'].toString()
                : t['fbErr']!;
            setState(() {
              sending = false;
              statusErr = errMsg;
            });
          }
        } catch (_) {
          setState(() {
            sending = false;
            statusErr = t['fbErr']!;
          });
        }
      }

      return CustomAlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lightbulb_outline_rounded,
                color: Color(0xFFF59E0B), size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(t['fbTitle']!,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 420, maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t['fbCat']!,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Theme.of(context).dividerColor.withOpacity(0.5)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: category,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(
                          value: 'suggestion', child: Text(t['fbCatSug']!)),
                      DropdownMenuItem(
                          value: 'feature', child: Text(t['fbCatFeat']!)),
                      DropdownMenuItem(
                          value: 'bug', child: Text(t['fbCatBug']!)),
                      DropdownMenuItem(
                          value: 'doubt', child: Text(t['fbCatDoubt']!)),
                      DropdownMenuItem(
                          value: 'criticism', child: Text(t['fbCatCrit']!)),
                    ],
                    onChanged: sending
                        ? null
                        : (v) {
                            if (v != null) setState(() => category = v);
                          },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: subjCtrl,
                enabled: !sending,
                decoration: InputDecoration(
                  labelText: t['fbSubj']!,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: emailCtrl,
                enabled: !sending,
                decoration: InputDecoration(
                  labelText: t['fbEmail']!,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: msgCtrl,
                enabled: !sending,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: t['fbMsg']!,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (statusErr.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(statusErr,
                      style:
                          const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
            ],
          ),
        ),
        actions: [
          dialogButton(t['fbCancel']!,
              onPressed: sending ? null : () => close(), isOutline: true),
          dialogButton(t['fbSend']!, onPressed: sending ? null : submit),
        ],
        onCancel: close,
      );
    });
  }

  int _compareSemver(String a, String b) {
    final pa = a
        .replaceAll(RegExp(r'[^0-9.]'), '')
        .split('.')
        .where((e) => e.isNotEmpty)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final pb = b
        .replaceAll(RegExp(r'[^0-9.]'), '')
        .split('.')
        .where((e) => e.isNotEmpty)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (int i = 0; i < n; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final lang = _activeLangCode();
    final t = _tr(lang);
    final curVer = version.isNotEmpty ? version : '1.5.2';
    Map<String, dynamic>? manifest;

    for (final url in const [
      'https://remote.2048quantix.com/downloads/manifest.json',
      'https://remote.2048quantix.com/api/version',
    ]) {
      try {
        final res =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final parsed = jsonDecode(res.body);
          if (parsed is Map<String, dynamic> &&
              (parsed['version']?.toString().isNotEmpty ?? false)) {
            manifest = parsed;
            break;
          }
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _checkingUpdate = false);
    }

    if (manifest == null) {
      showToast(t['updFail']!);
      return;
    }

    final remoteVer = manifest['version']?.toString() ?? curVer;
    final dlUrl = manifest['download_url']?.toString() ??
        'https://remote.2048quantix.com/download/QuantixRemoto.exe';
    final hasUpdate = _compareSemver(remoteVer, curVer) > 0;

    gFFI.dialogManager.show((setState, close, context) {
      return CustomAlertDialog(
        title: Row(
          children: [
            Icon(
              hasUpdate ? Icons.system_update_alt_rounded : Icons.verified_rounded,
              color: hasUpdate ? const Color(0xFF55D8CC) : const Color(0xFF10B981),
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(t['updTitle']!,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(hasUpdate ? t['updNew']! : t['updLatest']!,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text('${t['updCur']!}: v$curVer',
                  style: const TextStyle(fontSize: 12.5)),
              Text('${t['updAvail']!}: v$remoteVer',
                  style: const TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        actions: [
          dialogButton(t['updClose']!, onPressed: close, isOutline: hasUpdate),
          if (hasUpdate)
            dialogButton(t['updDownload']!, onPressed: () {
              close();
              launchUrlString(dlUrl);
            }),
        ],
        onCancel: close,
      );
    });
  }

  Future<void> _selectLanguage(String langKey) async {
    await bind.mainSetLocalOption(key: kCommConfKeyLang, value: langKey);
    if (isWeb) {
      reloadCurrentWindow();
    } else {
      bind.mainChangeLanguage(lang: langKey);
      reloadAllWindows();
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleTheme() async {
    final isDark = MyTheme.currentThemeMode() == ThemeMode.dark;
    await MyTheme.changeDarkMode(isDark ? ThemeMode.light : ThemeMode.dark);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lang = _activeLangCode();
    final t = _tr(lang);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = MyTheme.tabbar(context).unSelectedIconColor;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: t['fbTip']!,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            onTap: _openFeedbackDialog,
            hoverColor: MyTheme.tabbar(context).hoverColor,
            child: SizedBox(
              height: _kTabBarHeight - 1,
              width: _kTabBarHeight,
              child: const Icon(
                Icons.lightbulb_outline_rounded,
                size: 15,
                color: Color(0xFFF59E0B),
              ),
            ),
          ),
        ),
        Tooltip(
          message: t['updTip']!,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            onTap: _checkingUpdate ? null : _checkUpdates,
            hoverColor: MyTheme.tabbar(context).hoverColor,
            child: SizedBox(
              height: _kTabBarHeight - 1,
              width: _kTabBarHeight,
              child: _checkingUpdate
                  ? Padding(
                      padding: const EdgeInsets.all(7),
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: iconColor,
                      ),
                    )
                  : Icon(
                      Icons.sync_rounded,
                      size: 15,
                      color: iconColor,
                    ),
            ),
          ),
        ),
        Tooltip(
          message: t['langTip']!,
          waitDuration: const Duration(milliseconds: 500),
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            tooltip: '',
            onSelected: _selectLanguage,
            itemBuilder: (ctx) => _langs
                .map((l) => PopupMenuItem<String>(
                      value: l['key']!,
                      height: 32,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text(l['short']!,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 12)),
                          ),
                          Text(l['label']!,
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ))
                .toList(),
            child: Container(
              height: 21,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: (iconColor ?? Colors.grey).withOpacity(0.28),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.language_rounded, size: 12, color: iconColor),
                  const SizedBox(width: 3),
                  Text(
                    _activeShortLabel(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: iconColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Tooltip(
          message: t['themeTip']!,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            onTap: _toggleTheme,
            hoverColor: MyTheme.tabbar(context).hoverColor,
            child: SizedBox(
              height: _kTabBarHeight - 1,
              width: _kTabBarHeight,
              child: Icon(
                isDark ? Icons.wb_sunny_rounded : Icons.nightlight_round,
                size: 15,
                color: isDark ? const Color(0xFFF59E0B) : const Color(0xFFD97706),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
