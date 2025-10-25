// lib/ar_ruler_screen.dart
// Flutter 3.35 / ar_flutter_plugin 0.7.3

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

// Remote GLB box as "dot" (no local assets required)
const _dotGlb =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/Box/glTF-Binary/Box.glb';

// ---------- math helpers ----------
double _len(vm.Vector3 v) => math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
double _dist3(vm.Vector3 a, vm.Vector3 b) => _len(a - b);

String _fmtLen(double m) => '${(m * 100).toStringAsFixed(1)} cm';
String _fmtArea(double m2) => '${(m2 * 1e4).toStringAsFixed(1)} cm²';
String _fmtVol(double m3) => '${(m3 * 1e6).toStringAsFixed(1)} cm³';

vm.Vector3 _posFromM4(vm.Matrix4 m) => vm.Vector3(m.storage[12], m.storage[13], m.storage[14]);
// Sceneform/ARCore: Y axis ~ plane normal
vm.Vector3 _normalFromM4(vm.Matrix4 m) => vm.Vector3(m.storage[4], m.storage[5], m.storage[6]).normalized();

vm.Vector3 _projectToPlane(vm.Vector3 p, vm.Vector3 o, vm.Vector3 n) {
  final vm.Vector3 op = p - o;
  return p - n * op.dot(n);
}

// ---------- modes & steps ----------
enum ProjectionMode { smart, lockToPlane, off3D }
enum ShapeMode { ruler, cone, cylinder, sphere, cube }

enum ConeStep { baseCenter, baseEdge, apex, done }
enum CylStep { baseCenter, baseEdge, topCenter, done }
enum SphereStep { p1, p2, done }
enum CubeStep { edgeStart, edgeEnd, done }

class ArrulerScreen extends StatefulWidget {
  const ArrulerScreen({super.key});
  @override
  State<ArrulerScreen> createState() => _ArrulerScreenState();
}

class _ArrulerScreenState extends State<ArrulerScreen> {
  late ARSessionManager _session;
  late ARObjectManager _objects;

  // Projection behavior & scale
  ProjectionMode _proj = ProjectionMode.smart;
  double _scale = 1.0; // multiplies meters

  // Current mode
  ShapeMode _mode = ShapeMode.ruler;

  // Locked plane (from first tap); used for planar measurements
  vm.Vector3? _planeO;
  vm.Vector3? _planeN;

  // Ruler points & visuals
  vm.Vector3? _pA, _pB;
  ARNode? _dotA, _dotB;
  final List<ARNode> _lineDots = [];
  double? _liveCm;

  // Cone
  ConeStep _coneStep = ConeStep.baseCenter;
  vm.Vector3? _coneBaseC, _coneBaseEdge, _coneApex;

  // Cylinder
  CylStep _cylStep = CylStep.baseCenter;
  vm.Vector3? _cylBaseC, _cylBaseEdge, _cylTopC;

  // Sphere
  SphereStep _sphereStep = SphereStep.p1;
  vm.Vector3? _sP1, _sP2;

  // Cube
  CubeStep _cubeStep = CubeStep.edgeStart;
  vm.Vector3? _cubeA, _cubeB;

  // (optional) histories if you later add undo/ghosts
  final List<ARNode> _tinyHistory = [];
  final List<ARNode> _ghostDots = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Measure'),
        actions: [
          IconButton(
            tooltip: 'Calibrate scale',
            icon: const Icon(Icons.tune),
            onPressed: _calibrate,
          ),
          PopupMenuButton<String>(
            tooltip: 'Projection / Reset',
            onSelected: _handleProjectionMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'smart', child: Text('Projection: Smart')),
              PopupMenuItem(value: 'plane', child: Text('Projection: Lock to plane')),
              PopupMenuItem(value: '3d', child: Text('Projection: 3D')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'relock', child: Text('Relock plane on next tap')),
              PopupMenuItem(value: 'reset', child: Text('Reset all')),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        ARView(
          onARViewCreated: _onARViewCreated,
          planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
        ),
        Positioned(left: 12, right: 12, bottom: 18, child: _hud()),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickShape,
        icon: const Icon(Icons.category),
        label: Text('Mode: ${_mode.name.toUpperCase()}'),
      ),
    );
  }

  Widget _hud() {
    String main;
    switch (_mode) {
      case ShapeMode.ruler:
        if (_pA == null) main = 'Tap START';
        else if (_pB == null) main = 'Tap END';
        else main = _liveCm == null ? '...' : '${_liveCm!.toStringAsFixed(1)} cm';
        break;
      case ShapeMode.cone:
        main = switch (_coneStep) {
          ConeStep.baseCenter => 'Cone: tap BASE CENTER',
          ConeStep.baseEdge   => 'Cone: tap a BASE EDGE point (radius)',
          ConeStep.apex       => 'Cone: tap APEX (tip)',
          ConeStep.done       => 'Cone: tap to start new',
        };
        break;
      case ShapeMode.cylinder:
        main = switch (_cylStep) {
          CylStep.baseCenter => 'Cylinder: tap BASE CENTER',
          CylStep.baseEdge   => 'Cylinder: tap BASE EDGE (radius)',
          CylStep.topCenter  => 'Cylinder: tap TOP CENTER',
          CylStep.done       => 'Cylinder: tap to start new',
        };
        break;
      case ShapeMode.sphere:
        main = switch (_sphereStep) {
          SphereStep.p1  => 'Sphere: tap point on surface',
          SphereStep.p2  => 'Sphere: tap opposite point (diameter)',
          SphereStep.done=> 'Sphere: tap to start new',
        };
        break;
      case ShapeMode.cube:
        main = switch (_cubeStep) {
          CubeStep.edgeStart => 'Cube: tap EDGE START',
          CubeStep.edgeEnd   => 'Cube: tap EDGE END',
          CubeStep.done      => 'Cube: tap to start new',
        };
        break;
    }

    final planeStr = (_planeO != null) ? 'Plane: locked' : 'Plane: (locks on 1st tap)';
    final projStr = switch (_proj) {
      ProjectionMode.smart => 'Smart',
      ProjectionMode.lockToPlane => 'Lock',
      ProjectionMode.off3D => '3D',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(main, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$planeStr • Mode: $projStr • Scale x${_scale.toStringAsFixed(3)}'),
        ]),
      ),
    );
  }

  // --------------------------- AR setup ---------------------------
  Future<void> _onARViewCreated(
      ARSessionManager s,
      ARObjectManager o,
      ARAnchorManager a,
      ARLocationManager l,
      ) async {
    _session = s;
    _objects = o;

    await _session.onInitialize(
      handleTaps: true,
      handlePans: false,
      showPlanes: true,
      showFeaturePoints: false,
      showWorldOrigin: false,
    );
    await _objects.onInitialize();

    _session.onPlaneOrPointTap = (hits) async {
      if (hits.isEmpty) return;
      final m = hits.first.worldTransform;
      final p = _posFromM4(m);
      final n = _normalFromM4(m);

      // lock plane from first tap (or after "relock")
      _planeO ??= p;
      _planeN ??= n;

      switch (_mode) {
        case ShapeMode.ruler:    await _tapRuler(p);    break;
        case ShapeMode.cone:     await _tapCone(p);     break;
        case ShapeMode.cylinder: await _tapCylinder(p); break;
        case ShapeMode.sphere:   await _tapSphere(p);   break;
        case ShapeMode.cube:     await _tapCube(p);     break;
      }
      setState(() {});
    };
  }

  // --------------------------- projection & distance ---------------------------
  bool _nearLockedPlane(vm.Vector3 p, {double eps = 0.02}) {
    if (_planeO == null || _planeN == null) return false;
    return ((p - _planeO!).dot(_planeN!).abs() <= eps);
  }

  double _distanceSmart(vm.Vector3 a, vm.Vector3 b) {
    // meters before scale
    final d3 = _dist3(a, b);
    if (_proj == ProjectionMode.off3D) return d3 * _scale;

    if (_planeO != null && _planeN != null) {
      final ap = _projectToPlane(a, _planeO!, _planeN!);
      final bp = _projectToPlane(b, _planeO!, _planeN!);
      final dp = _dist3(ap, bp);
      if (_proj == ProjectionMode.lockToPlane) return dp * _scale;

      // smart: if both points lie "near" the plane, prefer planar dist
      if (_nearLockedPlane(a) && _nearLockedPlane(b)) return dp * _scale;
    }
    return d3 * _scale;
  }

  // orthogonal height to locked plane (for cylinder/cone)
  double _heightToLockedPlane(vm.Vector3 baseCenter, vm.Vector3 topCenter) {
    if (_planeN == null) return _dist3(baseCenter, topCenter) * _scale;
    final diff = topCenter - baseCenter;
    final h = diff.dot(_planeN!).abs(); // true perpendicular height
    return h * _scale;
  }

  // --------------------------- RULER ---------------------------
  Future<void> _tapRuler(vm.Vector3 p) async {
    if (_pA == null) {
      _pA = p;
      await _placeDot(isA: true, at: p, size: 0.014);
      await _clearLine();
      _pB = null;
      _liveCm = null;
    } else if (_pB == null) {
      _pB = p;
      await _placeDot(isA: false, at: p, size: 0.012);
      await _drawDottedBetween(_pA!, _pB!);
      _liveCm = _distanceSmart(_pA!, _pB!) * 100.0;
    } else {
      await _resetMeasureVisuals();
      _pA = p;
      await _placeDot(isA: true, at: p, size: 0.014);
    }
  }

  // --------------------------- CONE ---------------------------
  Future<void> _tapCone(vm.Vector3 p) async {
    switch (_coneStep) {
      case ConeStep.baseCenter:
        _coneBaseC = p;
        await _placeTiny(p);
        _coneStep = ConeStep.baseEdge;
        break;

      case ConeStep.baseEdge:
        _coneBaseEdge = p;
        await _placeTiny(p);
        // show radius line on plane
        await _drawDottedBetween(_projectToPlane(_coneBaseC!, _planeO!, _planeN!),
            _projectToPlane(_coneBaseEdge!, _planeO!, _planeN!));
        _coneStep = ConeStep.apex;
        break;

      case ConeStep.apex:
        _coneApex = p;
        await _placeTiny(p);
        // show height guide
        await _drawDottedBetween(_coneBaseC!, _coneApex!);
        _computeCone();
        _coneStep = ConeStep.done;
        break;

      case ConeStep.done:
        await _resetAll();
        _mode = ShapeMode.cone;
        _toast('Cone: tap BASE CENTER');
        break;
    }
  }

  void _computeCone() {
    // radius measured on base plane, height orthogonal to base plane
    final vm.Vector3 baseC = _coneBaseC!;
    final vm.Vector3 baseR = _coneBaseEdge!;
    final vm.Vector3 apex  = _coneApex!;
    final vm.Vector3 o = _planeO!, n = _planeN!;

    final r = _dist3(_projectToPlane(baseC, o, n), _projectToPlane(baseR, o, n)) * _scale;
    final h = _heightToLockedPlane(baseC, apex);
    final s = math.sqrt(r * r + h * h);
    final vol = (math.pi * r * r * h) / 3.0;
    final areaLateral = math.pi * r * s;
    final areaTotal = math.pi * r * (r + s);

    _showResult('Cone', [
      'r = ${_fmtLen(r)}',
      'h = ${_fmtLen(h)}',
      'Volume = ${_fmtVol(vol)}',
      'Area (side) = ${_fmtArea(areaLateral)}',
      'Area (total) = ${_fmtArea(areaTotal)}',
    ]);
  }

  // --------------------------- CYLINDER ---------------------------
  Future<void> _tapCylinder(vm.Vector3 p) async {
    switch (_cylStep) {
      case CylStep.baseCenter:
        _cylBaseC = p;
        await _placeTiny(p);
        _cylStep = CylStep.baseEdge;
        break;

      case CylStep.baseEdge:
        _cylBaseEdge = p;
        await _placeTiny(p);
        // visualize planar radius
        final a = _projectToPlane(_cylBaseC!, _planeO!, _planeN!);
        final b = _projectToPlane(_cylBaseEdge!, _planeO!, _planeN!);
        await _drawDottedBetween(a, b);
        _cylStep = CylStep.topCenter;
        break;

      case CylStep.topCenter:
        _cylTopC = p;
        await _placeTiny(p);

        final r = _dist3(
          _projectToPlane(_cylBaseC!, _planeO!, _planeN!),
          _projectToPlane(_cylBaseEdge!, _planeO!, _planeN!),
        ) * _scale;

        final h = _heightToLockedPlane(_cylBaseC!, _cylTopC!);

        final vol = math.pi * r * r * h;
        final areaLateral = 2 * math.pi * r * h;
        final areaTotal = 2 * math.pi * r * (r + h);

        _showResult('Cylinder', [
          'r = ${_fmtLen(r)}',
          'h = ${_fmtLen(h)}',
          'Volume = ${_fmtVol(vol)}',
          'Area (side) = ${_fmtArea(areaLateral)}',
          'Area (total) = ${_fmtArea(areaTotal)}',
        ]);

        _cylStep = CylStep.done;
        break;

      case CylStep.done:
        await _resetAll();
        _mode = ShapeMode.cylinder;
        _toast('Cylinder: tap BASE CENTER');
        break;
    }
  }

  // --------------------------- SPHERE ---------------------------
  Future<void> _tapSphere(vm.Vector3 p) async {
    switch (_sphereStep) {
      case SphereStep.p1:
        _sP1 = p;
        await _placeTiny(p);
        _sphereStep = SphereStep.p2;
        break;

      case SphereStep.p2:
        _sP2 = p;
        await _placeTiny(p);
        await _drawDottedBetween(_sP1!, _sP2!);
        final d = _distanceSmart(_sP1!, _sP2!); // diameter
        final r = d / 2.0;
        final vol = (4.0 / 3.0) * math.pi * r * r * r;
        final area = 4.0 * math.pi * r * r;

        _showResult('Sphere', [
          'd = ${_fmtLen(d)}',
          'r = ${_fmtLen(r)}',
          'Volume = ${_fmtVol(vol)}',
          'Area = ${_fmtArea(area)}',
        ]);

        _sphereStep = SphereStep.done;
        break;

      case SphereStep.done:
        await _resetAll();
        _mode = ShapeMode.sphere;
        _toast('Sphere: tap first point');
        break;
    }
  }

  // --------------------------- CUBE ---------------------------
  Future<void> _tapCube(vm.Vector3 p) async {
    switch (_cubeStep) {
      case CubeStep.edgeStart:
        _cubeA = p;
        await _placeTiny(p);
        _cubeStep = CubeStep.edgeEnd;
        break;

      case CubeStep.edgeEnd:
        _cubeB = p;
        await _placeTiny(p);
        await _drawDottedBetween(_cubeA!, _cubeB!);
        final a = _distanceSmart(_cubeA!, _cubeB!);
        final vol = a * a * a;
        final surf = 6 * a * a;
        _showResult('Cube', [
          'a = ${_fmtLen(a)}',
          'Volume = ${_fmtVol(vol)}',
          'Surface = ${_fmtArea(surf)}',
        ]);
        _cubeStep = CubeStep.done;
        break;

      case CubeStep.done:
        await _resetAll();
        _mode = ShapeMode.cube;
        _toast('Cube: tap EDGE START');
        break;
    }
  }

  // --------------------------- visuals ---------------------------
  Future<void> _placeDot({
    required bool isA,
    required vm.Vector3 at,
    double size = 0.01,
  }) async {
    final node = ARNode(type: NodeType.webGLB, uri: _dotGlb, position: at, scale: vm.Vector3.all(size));
    if (isA && _dotA != null) await _safeRemove(_dotA!);
    if (!isA && _dotB != null) await _safeRemove(_dotB!);
    await _objects.addNode(node);
    if (isA) {
      _dotA = node;
    } else {
      _dotB = node;
    }
  }

  Future<void> _placeTiny(vm.Vector3 at) async {
    final node = ARNode(type: NodeType.webGLB, uri: _dotGlb, position: at, scale: vm.Vector3.all(0.008));
    await _objects.addNode(node);
    _lineDots.add(node);
    _tinyHistory.add(node);
  }

  Future<void> _drawDottedBetween(
      vm.Vector3 a,
      vm.Vector3 b, {
        double spacingMeters = 0.018,
        bool clearExisting = true,
      }) async {
    if (clearExisting) await _clearLine();

    final len = _dist3(a, b);
    if (len <= 0) return;

    final int n = (len / spacingMeters).clamp(4, 160).round();
    for (int i = 1; i < n; i++) {
      final t = i / n;
      final p = vm.Vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t,
      );
      await _placeTiny(p);
    }
  }

  Future<void> _clearLine() async {
    for (final node in _lineDots) {
      await _safeRemove(node);
    }
    _lineDots.clear();
    _tinyHistory.clear();
  }

  Future<void> _resetMeasureVisuals() async {
    await _clearLine();
    for (final node in _ghostDots) {
      await _safeRemove(node);
    }
    _ghostDots.clear();

    if (_dotA != null) { await _safeRemove(_dotA!); _dotA = null; }
    if (_dotB != null) { await _safeRemove(_dotB!); _dotB = null; }

    _pA = null; _pB = null; _liveCm = null;
  }

  Future<void> _resetAll() async {
    await _resetMeasureVisuals();
    _planeO = null; _planeN = null;
    _scale = 1.0;

    _coneStep = ConeStep.baseCenter; _coneBaseC = _coneBaseEdge = _coneApex = null;
    _cylStep  = CylStep.baseCenter;  _cylBaseC  = _cylBaseEdge  = _cylTopC   = null;
    _sphereStep = SphereStep.p1;     _sP1 = _sP2 = null;
    _cubeStep = CubeStep.edgeStart;  _cubeA = _cubeB = null;

    setState(() {});
  }

  // --------------------------- menus & dialogs ---------------------------
  Future<void> _pickShape() async {
    final sel = await showModalBottomSheet<ShapeMode>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.straighten), title: const Text('Ruler (2-tap)'),
              onTap: ()=>Navigator.pop(context, ShapeMode.ruler)),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.icecream), title: const Text('Cone'),
              onTap: ()=>Navigator.pop(context, ShapeMode.cone)),
          ListTile(leading: const Icon(Icons.view_week), title: const Text('Cylinder'),
              onTap: ()=>Navigator.pop(context, ShapeMode.cylinder)),
          ListTile(leading: const Icon(Icons.circle_outlined), title: const Text('Sphere'),
              onTap: ()=>Navigator.pop(context, ShapeMode.sphere)),
          ListTile(leading: const Icon(Icons.all_inbox), title: const Text('Cube'),
              onTap: ()=>Navigator.pop(context, ShapeMode.cube)),
          const SizedBox(height: 6),
        ]),
      ),
    );

    if (sel == null) return;
    await _resetAll();
    setState(() => _mode = sel);

    switch (_mode) {
      case ShapeMode.ruler: _toast('Ruler: tap START then END'); break;
      case ShapeMode.cone: _toast('Cone: tap BASE CENTER'); break;
      case ShapeMode.cylinder: _toast('Cylinder: tap BASE CENTER'); break;
      case ShapeMode.sphere: _toast('Sphere: tap first point'); break;
      case ShapeMode.cube: _toast('Cube: tap EDGE START'); break;
    }
  }

  void _showResult(String title, List<String> lines) {
    showDialog(context: context, builder: (_) {
      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines.map(Text.new).toList(),
        ),
        actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: const Text('OK'))],
      );
    });
  }

  // --------------------------- calibration ---------------------------
  Future<void> _calibrate() async {
    // Choose the most recent 2 points relevant to the mode
    vm.Vector3? a, b;
    switch (_mode) {
      case ShapeMode.ruler: a = _pA; b = _pB; break;
      case ShapeMode.cone: a = _coneBaseC; b = _coneBaseEdge; break;
      case ShapeMode.cylinder: a = _cylBaseC; b = _cylBaseEdge; break;
      case ShapeMode.sphere: a = _sP1; b = _sP2; break;
      case ShapeMode.cube: a = _cubeA; b = _cubeB; break;
    }
    if (a == null || b == null) { _toast('Make a measurement first.'); return; }

    final currentM = _distanceSmart(a, b); // already scaled
    final currentCm = currentM * 100.0;
    final ctrl = TextEditingController(text: currentCm.toStringAsFixed(1));

    final realCm = await showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Calibrate scale'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter the REAL distance (cm) between the last two points.'),
          const SizedBox(height: 8),
          TextField(controller: ctrl, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 6),
          Text('Measured now: ${currentCm.toStringAsFixed(1)} cm'),
        ]),
        actions: [
          TextButton(onPressed: ()=>Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: (){
            Navigator.pop(context, double.tryParse(ctrl.text.trim()));
          }, child: const Text('Apply')),
        ],
      ),
    );

    if (realCm == null || realCm <= 0) return;
    final realM = realCm / 100.0;
    final safe = currentM <= 1e-6 ? 1e-6 : currentM;
    setState(()=> _scale *= (realM / safe));
    _toast('Scale set to x${_scale.toStringAsFixed(3)}');
  }

  // --------------------------- utilities ---------------------------
  void _handleProjectionMenu(String s) async {
    switch (s) {
      case 'smart': setState(()=>_proj = ProjectionMode.smart); _toast('Projection: Smart'); break;
      case 'plane': setState(()=>_proj = ProjectionMode.lockToPlane); _toast('Projection: Lock'); break;
      case '3d': setState(()=>_proj = ProjectionMode.off3D); _toast('Projection: 3D'); break;
      case 'relock': _planeO = null; _planeN = null; _toast('Plane relock on next tap'); break;
      case 'reset': await _resetAll(); _toast('Reset'); break;
    }
  }

  Future<void> _safeRemove(ARNode node) async {
    try { await _objects.removeNode(node); } catch (_) {}
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
}
