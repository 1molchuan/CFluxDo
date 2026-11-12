import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 把活跃阅读页的工具放进工作台状态栏，避免正文上方再叠一条底栏。
class VscodeReaderStatusHost extends StatefulWidget {
  const VscodeReaderStatusHost({super.key, required this.child});

  final Widget child;

  @override
  State<VscodeReaderStatusHost> createState() => _VscodeReaderStatusHostState();
}

class _VscodeReaderStatusHostState extends State<VscodeReaderStatusHost> {
  final controller = VscodeReaderStatusController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VscodeReaderStatusScope(
    controller: controller,
    child: SizedBox(key: controller._workbenchKey, child: widget.child),
  );
}

class VscodeReaderStatusController extends ValueNotifier<Widget?> {
  VscodeReaderStatusController() : super(null);

  final _workbenchKey = GlobalKey();
  final _entries = <Object, ({Widget controls, double inset})>{};
  double _leadingInset = 0;
  double get leadingInset => _leadingInset;
  bool _disposed = false;

  void attach(Object owner, Widget controls, {double leadingInset = 0}) {
    if (_disposed) return;
    final existing = _entries[owner];
    if (_entries.keys.lastOrNull == owner &&
        identical(existing?.controls, controls) &&
        existing?.inset == leadingInset) {
      return;
    }
    _entries.remove(owner);
    _entries[owner] = (controls: controls, inset: leadingInset);
    _publish();
  }

  void _publish() {
    final entry = _entries.values.lastOrNull;
    final inset = entry?.inset ?? 0;
    final moved = _leadingInset != inset;
    _leadingInset = inset;
    if (identical(value, entry?.controls)) {
      if (moved) notifyListeners();
    } else {
      value = entry?.controls;
    }
  }

  void detach(Object owner) {
    if (_disposed || _entries.remove(owner) == null) return;
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    _entries.clear();
    super.dispose();
  }
}

class VscodeReaderStatusScope extends InheritedWidget {
  const VscodeReaderStatusScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final VscodeReaderStatusController controller;

  static VscodeReaderStatusController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<VscodeReaderStatusScope>()
      ?.controller;

  @override
  bool updateShouldNotify(VscodeReaderStatusScope oldWidget) =>
      controller != oldWidget.controller;
}

/// 注册以页面实例为所有者；缓存页失活或退栈时不能留下过期操作。
class VscodeReaderStatusBinding extends StatefulWidget {
  const VscodeReaderStatusBinding({
    super.key,
    required this.controls,
    required this.active,
  });

  final Widget controls;
  final bool active;

  @override
  State<VscodeReaderStatusBinding> createState() =>
      _VscodeReaderStatusBindingState();
}

class _VscodeReaderStatusBindingState extends State<VscodeReaderStatusBinding> {
  VscodeReaderStatusController? _controller;
  final _anchorKey = GlobalKey();
  bool _updateScheduled = false;

  void _scheduleUpdate() {
    if (_updateScheduled || !mounted) return;
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted) return;
      if (widget.active) {
        final anchor = _anchorKey.currentContext?.findRenderObject();
        final workbench = _controller?._workbenchKey.currentContext
            ?.findRenderObject();
        final inset =
            anchor is RenderBox &&
                workbench is RenderBox &&
                anchor.attached &&
                workbench.attached &&
                workbench.hasSize
            ? anchor
                  .localToGlobal(Offset.zero, ancestor: workbench)
                  .dx
                  .clamp(0.0, workbench.size.width)
            : 0.0;
        _controller?.attach(this, widget.controls, leadingInset: inset);
      } else {
        _controller?.detach(this);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = VscodeReaderStatusScope.maybeOf(context);
    if (next != _controller) {
      final previous = _controller;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => previous?.detach(this),
      );
      _controller = next;
    }
    _scheduleUpdate();
  }

  @override
  void didUpdateWidget(VscodeReaderStatusBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleUpdate();
  }

  @override
  void dispose() {
    final controller = _controller;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller?.detach(this),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReaderStatusAnchor(
    key: _anchorKey,
    onGeometryChanged: _scheduleUpdate,
    child: const SizedBox(width: double.infinity, height: 0),
  );
}

/// 几何变化后按实际渲染坐标发布，不复制分栏比例或导航栏宽度规则。
class _ReaderStatusAnchor extends SingleChildRenderObjectWidget {
  const _ReaderStatusAnchor({
    super.key,
    required this.onGeometryChanged,
    required super.child,
  });

  final VoidCallback onGeometryChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReaderStatusAnchor(onGeometryChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderReaderStatusAnchor renderObject,
  ) => renderObject.onGeometryChanged = onGeometryChanged;
}

class _RenderReaderStatusAnchor extends RenderProxyBox {
  _RenderReaderStatusAnchor(this.onGeometryChanged);

  VoidCallback onGeometryChanged;
  double? _lastGlobalX;

  @override
  void performLayout() {
    super.performLayout();
    onGeometryChanged();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final x = localToGlobal(Offset.zero).dx;
    if (x != _lastGlobalX) {
      _lastGlobalX = x;
      onGeometryChanged();
    }
  }
}

/// 只有主阅读流把楼层动作迁往状态栏；回复弹层保留自己的操作入口。
class VscodeReaderFlowScope extends InheritedWidget {
  const VscodeReaderFlowScope({
    super.key,
    required this.selectedPost,
    required super.child,
  });

  final ValueNotifier<int?> selectedPost;

  static VscodeReaderFlowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VscodeReaderFlowScope>();

  static bool contains(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(VscodeReaderFlowScope oldWidget) =>
      selectedPost != oldWidget.selectedPost;
}
