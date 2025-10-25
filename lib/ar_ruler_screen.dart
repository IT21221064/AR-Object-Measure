import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

// AR plugin
import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin/models/ar_node.dart';
import 'package:ar_flutter_plugin/datatypes/node_types.dart';

const _boxGlb =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/Box/glTF-Binary/Box.glb';

// ------- Helpers -------
double _dist(vm.Vector3 a, vm.Vector3 b) => (a - b).length; // meters
String _fmtLen(double m)   => '${(m*100).toStringAsFixed(1)} cm';
String _fmtArea(double m2) => '${(m2*1e4).toStringAsFixed(1)} cm²';
String _fmtVol(double m3)  => '${(m3*1e6).toStringAsFixed(1)} cm³';

// Modes & steps
enum ShapeMode { none, cone, cylinder, sphere, cube }
enum ConeStep   { baseCenter, baseEdge, apex, done }
enum CylStep    { baseCenter, baseEdge, topCenter, done }
enum SphereStep { point1, point2, done }
enum CubeStep   { edgeStart, edgeEnd, done }

class ArrulerScreen extends StatefulWidget {
  const ArrulerScreen({super.key});
  @override
  State<ArrulerScreen> createState() => _ArrulerScreenState();
}

class _ArrulerScreenState extends State<ArrulerScreen> {
  late ARSessionManager _session;
  late ARObjectManager _objects;

  // Base ruler
  vm.Vector3? _startPos;
  vm.Vector3? _endPos;
  ARNode? _startDot;
  ARNode? _endDot;
  final List<ARNode> _lineDots = [];
  double? _liveCm;

  // Shape mode
  ShapeMode _mode = ShapeMode.none;

  // Labels for HUD
  final List<String> _currentLabels = [];

  // Cone
  ConeStep _coneStep = ConeStep.baseCenter;
  vm.Vector3? _coneBaseCenter, _coneBaseEdge, _coneApex;

  // Cylinder
  CylStep _cylStep = CylStep.baseCenter;
  bool _cylBaseConfirmed = false;
  vm.Vector3? _cylBaseCenter, _cylBaseEdge, _cylTopCenter;

  // Sphere
  SphereStep _sphereStep = SphereStep.point1;
  vm.Vector3? _sphereP1, _sphereP2;

  // Cube
  CubeStep _cubeStep = CubeStep.edgeStart;
  vm.Vector3? _cubeA, _cubeB;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Ruler')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickShape,
        label: const Text('Shape'),
        icon: const Icon(Icons.category),
      ),
      body: Stack(children: [
        ARView(
          onARViewCreated: _onARViewCreated,
          planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
        ),
        Positioned(left: 16, right: 16, bottom: 24, child: _hud()),
      ]),
    );
  }

  Widget _hud() {
    List<String> messages = [];
    if (_mode == ShapeMode.none) {
      if (_liveCm != null) messages.add('${_liveCm!.toStringAsFixed(1)} cm');
      else messages.add(_startPos == null ? 'Ruler: tap START' : 'Ruler: tap END');
    }
    messages.addAll(_currentLabels);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: messages.map((e) => Text(e, style: const TextStyle(color: Colors.yellow, fontSize: 16))).toList(),
      ),
    );
  }

  Future<void> _onARViewCreated(
      ARSessionManager s,
      ARObjectManager o,
      ARAnchorManager a,
      ARLocationManager l,
      ) async {
    _session  = s;
    _objects  = o;

    await _session.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      customPlaneTexturePath: null,
      showWorldOrigin: false,
      handleTaps: true,
      handlePans: false,
    );
    await _objects.onInitialize();

    _session.onPlaneOrPointTap = (hits) async {
      if (hits.isEmpty) return;
      final p = _pos(hits.first.worldTransform);
      switch (_mode) {
        case ShapeMode.none: await _handleRulerTap(p); break;
        case ShapeMode.cone: await _onTapCone(p); break;
        case ShapeMode.cylinder: await _onTapCylinder(p); break;
        case ShapeMode.sphere: await _onTapSphere(p); break;
        case ShapeMode.cube: await _onTapCube(p); break;
      }
    };
  }

  // ---------- Base ruler ----------
  Future<void> _handleRulerTap(vm.Vector3 p) async {
    if (_startPos == null) {
      _startPos = p;
      await _setStartDot(p);
      _endPos = null;
      await _clearLine();
      setState(() => _liveCm = null);
    } else if (_endPos == null) {
      _endPos = p;
      await _setEndDot(p);
      await _drawDottedBetween(_startPos!, _endPos!);
      _updateDistance();
    } else {
      await _reset();
      _startPos = p;
      await _setStartDot(p);
      setState(() => _liveCm = null);
    }
  }

  // ---------- Cone ----------
  Future<void> _onTapCone(vm.Vector3 p) async {
    switch (_coneStep) {
      case ConeStep.baseCenter:
        _coneBaseCenter = p;
        await _placeLabel(p, 'Base Center');
        _coneStep = ConeStep.baseEdge;
        break;
      case ConeStep.baseEdge:
        _coneBaseEdge = p;
        await _placeLabel(p, 'Radius Point');
        await _drawDottedBetween(_coneBaseCenter!, _coneBaseEdge!);
        _coneStep = ConeStep.apex;
        break;
      case ConeStep.apex:
        _coneApex = p;
        await _placeLabel(p, 'Apex');
        await _drawDottedBetween(_coneBaseCenter!, _coneApex!);
        _computeConeAndShow();
        _coneStep = ConeStep.done;
        break;
      case ConeStep.done:
        await _resetConeFlow();
        _toast('Cone: tap BASE CENTER');
        break;
    }
    setState(() {});
  }

  void _computeConeAndShow() {
    final r = _dist(_coneBaseCenter!, _coneBaseEdge!);
    final h = _dist(_coneBaseCenter!, _coneApex!);
    final s = math.sqrt(r*r + h*h);
    final v = (math.pi * r * r * h) / 3.0;
    final aLateral = math.pi * r * s;
    final aTotal   = math.pi * r * (r + s);

    _showResultDialog(
      title: 'Cone',
      lines: [
        'r = ${_fmtLen(r)}',
        'h = ${_fmtLen(h)}',
        'Volume = ${_fmtVol(v)}',
        'Area (side) = ${_fmtArea(aLateral)}',
        'Area (total) = ${_fmtArea(aTotal)}',
      ],
    );
  }

  Future<void> _resetConeFlow() async {
    await _reset();
    _coneBaseCenter = _coneBaseEdge = _coneApex = null;
    _coneStep = ConeStep.baseCenter;
  }

  // ---------- Cylinder ----------
  Future<void> _onTapCylinder(vm.Vector3 p) async {
    switch (_cylStep) {
      case CylStep.baseCenter:
        _cylBaseCenter = p;
        await _placeLabel(p, 'Base Center (1st)');
        _cylStep = CylStep.baseEdge;
        break;

      case CylStep.baseEdge:
        _cylBaseEdge = p;
        await _placeLabel(p, 'Radius Point');
        await _drawDottedBetween(_cylBaseCenter!, _cylBaseEdge!);
        _toast('Tap Base Center again to confirm, then Top Center');
        _cylBaseConfirmed = false;
        _cylStep = CylStep.topCenter;
        break;

      case CylStep.topCenter:
        if (!_cylBaseConfirmed) {
          _cylBaseCenter = p; // confirm base center
          await _placeLabel(p, 'Base Center (confirmed)');
          _toast('Now tap Top Center');
          _cylBaseConfirmed = true;
        } else {
          _cylTopCenter = p;
          await _placeLabel(p, 'Top Center');
          await _drawDottedBetween(_cylBaseCenter!, _cylTopCenter!);
          _computeCylinderAndShow();
          _cylStep = CylStep.done;
        }
        break;

      case CylStep.done:
        await _resetCylinderFlow();
        _toast('Cylinder: tap Base Center (1st)');
        break;
    }
    setState(() {});
  }

  void _computeCylinderAndShow() {
    final r = _dist(_cylBaseCenter!, _cylBaseEdge!);
    final h = _dist(_cylBaseCenter!, _cylTopCenter!);
    final v = math.pi * r * r * h;
    final aLateral = 2 * math.pi * r * h;
    final aTotal   = 2 * math.pi * r * (r + h);

    _showResultDialog(
      title: 'Cylinder',
      lines: [
        'r = ${_fmtLen(r)}',
        'h = ${_fmtLen(h)}',
        'Volume = ${_fmtVol(v)}',
        'Area (side) = ${_fmtArea(aLateral)}',
        'Area (total) = ${_fmtArea(aTotal)}',
      ],
    );
  }

  Future<void> _resetCylinderFlow() async {
    await _reset();
    _cylBaseCenter = _cylBaseEdge = _cylTopCenter = null;
    _cylStep = CylStep.baseCenter;
    _cylBaseConfirmed = false;
  }

  // ---------- Sphere ----------
  Future<void> _onTapSphere(vm.Vector3 p) async {
    switch (_sphereStep) {
      case SphereStep.point1:
        _sphereP1 = p;
        await _placeLabel(p, 'Point 1');
        _sphereStep = SphereStep.point2;
        break;
      case SphereStep.point2:
        _sphereP2 = p;
        await _placeLabel(p, 'Opposite Point');
        await _drawDottedBetween(_sphereP1!, _sphereP2!);
        _computeSphereAndShow();
        _sphereStep = SphereStep.done;
        break;
      case SphereStep.done:
        await _resetSphereFlow();
        _toast('Sphere: tap POINT 1');
        break;
    }
    setState(() {});
  }

  void _computeSphereAndShow() {
    final d = _dist(_sphereP1!, _sphereP2!);
    final r = d / 2.0;
    final v = (4.0/3.0) * math.pi * r*r*r;
    final a = 4.0 * math.pi * r*r;

    _showResultDialog(
      title: 'Sphere',
      lines: [
        'd = ${_fmtLen(d)}',
        'r = ${_fmtLen(r)}',
        'Volume = ${_fmtVol(v)}',
        'Area = ${_fmtArea(a)}',
      ],
    );
  }

  Future<void> _resetSphereFlow() async {
    await _reset();
    _sphereP1 = _sphereP2 = null;
    _sphereStep = SphereStep.point1;
  }

  // ---------- Cube ----------
  Future<void> _onTapCube(vm.Vector3 p) async {
    switch (_cubeStep) {
      case CubeStep.edgeStart:
        _cubeA = p;
        await _placeLabel(p, 'Edge Start');
        _cubeStep = CubeStep.edgeEnd;
        break;
      case CubeStep.edgeEnd:
        _cubeB = p;
        await _placeLabel(p, 'Edge End');
        await _drawDottedBetween(_cubeA!, _cubeB!);
        _computeCubeAndShow();
        _cubeStep = CubeStep.done;
        break;
      case CubeStep.done:
        await _resetCubeFlow();
        _toast('Cube: tap EDGE START');
        break;
    }
    setState(() {});
  }

  void _computeCubeAndShow() {
    final a = _dist(_cubeA!, _cubeB!);
    final v = a*a*a;
    final s = 6 * a*a;

    _showResultDialog(
      title: 'Cube',
      lines: [
        'a = ${_fmtLen(a)}',
        'Volume = ${_fmtVol(v)}',
        'Surface = ${_fmtArea(s)}',
      ],
    );
  }

  Future<void> _resetCubeFlow() async {
    await _reset();
    _cubeA = _cubeB = null;
    _cubeStep = CubeStep.edgeStart;
  }

  // ---------- Common methods ----------
  vm.Vector3 _pos(vm.Matrix4 m) => vm.Vector3(m.storage[12], m.storage[13], m.storage[14]);

  Future<ARNode> _placeDot(vm.Vector3 p, {double scale = 0.01}) async {
    final n = ARNode(type: NodeType.webGLB, uri: _boxGlb, position: p, scale: vm.Vector3.all(scale));
    await _objects.addNode(n);
    _lineDots.add(n);
    return n;
  }

  Future<void> _placeLabel(vm.Vector3 p, String labelText) async {
    await _placeDot(p, scale: 0.008);
    _currentLabels.add(labelText);
    setState(() {});
  }

  Future<void> _setStartDot(vm.Vector3 p) async {
    if (_startDot != null) { await _objects.removeNode(_startDot!); _startDot = null; }
    _startDot = ARNode(type: NodeType.webGLB, uri: _boxGlb, position: p, scale: vm.Vector3.all(0.012));
    await _objects.addNode(_startDot!);
  }

  Future<void> _setEndDot(vm.Vector3 p) async {
    if (_endDot != null) { await _objects.removeNode(_endDot!); _endDot = null; }
    _endDot = ARNode(type: NodeType.webGLB, uri: _boxGlb, position: p, scale: vm.Vector3.all(0.010));
    await _objects.addNode(_endDot!);
  }

  Future<void> _drawDottedBetween(vm.Vector3 a, vm.Vector3 b) async {
    final lenM = (a - b).length;
    if (lenM <= 0) return;
    final int n = (lenM / 0.018).clamp(4, 120).round();
    for (int i = 1; i < n; i++) {
      final t = i / n;
      final p = vm.Vector3(a.x + (b.x - a.x)*t, a.y + (b.y - a.y)*t, a.z + (b.z - a.z)*t);
      await _placeDot(p, scale: 0.006);
    }
  }

  void _updateDistance() {
    if (_startPos == null || _endPos == null) return;
    final a = _startPos!, b = _endPos!;
    final meters = _dist(a, b);
    setState(() => _liveCm = meters * 100.0);
  }

  Future<void> _clearLine() async {
    for (final n in _lineDots) await _objects.removeNode(n);
    _lineDots.clear();
  }

  Future<void> _reset() async {
    await _clearLine();
    _currentLabels.clear();
    if (_startDot != null) { await _objects.removeNode(_startDot!); _startDot = null; }
    if (_endDot != null) { await _objects.removeNode(_endDot!); _endDot = null; }
    _startPos = null; _endPos = null; _liveCm = null;
    setState(() {});
  }

  Future<void> _resetAll() async {
    await _reset();
    _coneStep   = ConeStep.baseCenter;
    _cylStep    = CylStep.baseCenter;
    _cylBaseConfirmed = false;
    _sphereStep = SphereStep.point1;
    _cubeStep   = CubeStep.edgeStart;

    _coneBaseCenter = _coneBaseEdge = _coneApex = null;
    _cylBaseCenter = _cylBaseEdge = _cylTopCenter = null;
    _sphereP1 = _sphereP2 = null;
    _cubeA = _cubeB = null;

    _toast('Reset');
  }

  void _showResultDialog({required String title, required List<String> lines}) {
    showDialog(context: context, builder: (_) {
      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines.map((e) => Text(e)).toList(),
        ),
        actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: const Text('OK'))],
      );
    });
  }

  Future<void> _pickShape() async {
    final selected = await showModalBottomSheet<ShapeMode>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.straighten), title: const Text('Ruler (2-tap)'), onTap: ()=> Navigator.pop(context, ShapeMode.none)),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.icecream), title: const Text('Cone'), onTap: ()=> Navigator.pop(context, ShapeMode.cone)),
          ListTile(leading: const Icon(Icons.view_week), title: const Text('Cylinder'), onTap: ()=> Navigator.pop(context, ShapeMode.cylinder)),
          ListTile(leading: const Icon(Icons.circle_outlined), title: const Text('Sphere'), onTap: ()=> Navigator.pop(context, ShapeMode.sphere)),
          ListTile(leading: const Icon(Icons.all_inbox), title: const Text('Cube'), onTap: ()=> Navigator.pop(context, ShapeMode.cube)),
        ]),
      ),
    );

    if (selected == null) return;

    await _resetAll();
    _mode = selected;

    switch (_mode) {
      case ShapeMode.none: _toast('Ruler: tap START then END'); break;
      case ShapeMode.cone: _toast('Cone: tap BASE CENTER'); break;
      case ShapeMode.cylinder: _toast('Cylinder: tap BASE CENTER (1st)'); break;
      case ShapeMode.sphere: _toast('Sphere: tap POINT 1'); break;
      case ShapeMode.cube: _toast('Cube: tap EDGE START'); break;
    }
    setState(() {});
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }
}
