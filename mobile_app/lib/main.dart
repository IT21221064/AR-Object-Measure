// lib/main.dart
import 'dart:io';
import 'dart:math';

import 'package:ar_flutter_plugin_updated/widgets/ar_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:path_provider/path_provider.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3, Matrix4;

import 'package:ar_flutter_plugin_updated/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_updated/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_updated/datatypes/node_types.dart';

import 'package:ar_flutter_plugin_updated/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_session_manager.dart';

import 'package:ar_flutter_plugin_updated/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_updated/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_updated/models/ar_node.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Measure Fallback Ready',
      theme: ThemeData.dark(),
      home: const ARMeasurePage(),
    );
  }
}

class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePageState extends State<ARMeasurePage> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  ARLocationManager? arLocationManager;

  final List<ARAnchor> anchors = [];
  final List<ARNode> anchorNodes = [];
  final List<ARNode> lineNodes = [];

  double measuredMeters = 0.0;

  final Vector3 markerScale = Vector3(0.03, 0.03, 0.03);
  final Vector3 dotScale = Vector3(0.01, 0.01, 0.01);

  final int lineDots = 20;

  String _modelAsset = 'assets/models/sphere.gltf';
  String? _modelDocFullPath;
  String? _modelDocFileName;

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }

  // PREPARE GLB (fallback loader)
  Future<void> _prepareModel() async {
    debugPrint('Preparing model $_modelAsset');

    // 1 — ensure asset exists
    try {
      final bd = await rootBundle.load(_modelAsset);
      debugPrint('Asset exists: $_modelAsset (${bd.lengthInBytes} bytes)');
    } catch (e) {
      debugPrint('ERROR: asset $_modelAsset not found!');
      return;
    }

    // 2 — copy into documents folder
    try {
      final data = await rootBundle.load(_modelAsset);
      final bytes = data.buffer.asUint8List();

      final dir = await getApplicationDocumentsDirectory();
      final fileName = _modelAsset.split('/').last;

      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      _modelDocFullPath = file.path;
      _modelDocFileName = fileName;

      debugPrint('Copied model to: $_modelDocFullPath');
      debugPrint('Exists = ${await file.exists()}  size = ${await file.length()}');
    } catch (e) {
      debugPrint('ERROR copying to documents: $e');
    }
  }

  Future<ARNode?> _addNodeWithFallback({
    required String name,
    required Matrix4 transform,
    required Vector3 scale,
  }) async {
    // TRY 1: localGLTF2 from assets
    try {
      final node1 = ARNode(
        type: NodeType.localGLTF2,
        uri: _modelAsset,
        scale: scale,
        name: name,
        transformation: transform,
      );
      final ok1 = await arObjectManager?.addNode(node1);

      debugPrint('Try localGLTF2: $ok1');
      if (ok1 == true) return node1;
    } catch (e) {
      debugPrint('Try localGLTF2 error: $e');
    }

    // TRY 2: fileSystemAppFolderGLB using filename only
    if (_modelDocFileName != null) {
      try {
        final node2 = ARNode(
          type: NodeType.fileSystemAppFolderGLB,
          uri: _modelDocFileName!,
          scale: scale,
          name: name,
          transformation: transform,
        );

        final ok2 = await arObjectManager?.addNode(node2);
        debugPrint('Try fileSystemAppFolderGLB(filename): $ok2');

        if (ok2 == true) return node2;
      } catch (e) {
        debugPrint('Try FS(filename) error: $e');
      }
    }

    // TRY 3: full path
    if (_modelDocFullPath != null) {
      try {
        final node3 = ARNode(
          type: NodeType.fileSystemAppFolderGLB,
          uri: _modelDocFullPath!,
          scale: scale,
          name: name,
          transformation: transform,
        );

        final ok3 = await arObjectManager?.addNode(node3);
        debugPrint('Try fileSystemAppFolderGLB(full path): $ok3');

        if (ok3 == true) return node3;
      } catch (e) {
        debugPrint('Try FS(full path) error: $e');
      }
    }

    debugPrint('❌ All attempts to load GLB failed.');
    return null;
  }

  // =====================
  // === PART 2 START ====
  // =====================

  // Convert plugin transform → Matrix4
  Matrix4 _matrixFromTransform(dynamic t) {
    if (t is Matrix4) return t;

    if (t is List && t.length >= 16) {
      try {
        return Matrix4.fromList(List<double>.from(t));
      } catch (_) {
        return Matrix4(
          t[0], t[4], t[8], t[12],
          t[1], t[5], t[9], t[13],
          t[2], t[6], t[10], t[14],
          t[3], t[7], t[11], t[15],
        );
      }
    }

    return Matrix4.identity();
  }

  // When ARView is created
  Future<void> _onARViewCreated(
      ARSessionManager s,
      ARObjectManager o,
      ARAnchorManager a,
      ARLocationManager l,
      ) async {
    arSessionManager = s;
    arObjectManager = o;
    arAnchorManager = a;
    arLocationManager = l;

    // Enable features
    arSessionManager?.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: true,
    );

    try {
      await arObjectManager?.onInitialize();
    } catch (_) {}

    // IMPORTANT: prepare GLB model for fallback loading
    await _prepareModel();

    // Tap handler
    arSessionManager?.onPlaneOrPointTap = _onPlaneTap;
  }

  // Handle tapping on AR plane → place markers
  Future<void> _onPlaneTap(List<ARHitTestResult> hits) async {
    if (hits.isEmpty) return;

    final hit = hits.firstWhere(
          (h) => h.type == ARHitTestResultType.plane,
      orElse: () => hits.first,
    );

    final anchor = ARPlaneAnchor(transformation: hit.worldTransform);

    final ok = await arAnchorManager?.addAnchor(anchor);
    if (ok != true) {
      debugPrint("❌ FAILED to add anchor");
      return;
    }

    // Keep only 2 anchors (start + end)
    if (anchors.length >= 2) {
      await _removeOldestAnchor();
    }

    anchors.add(anchor);

    final transform = _matrixFromTransform(anchor.transformation);
    final isStart = anchors.length == 1;

    debugPrint("Placing ${isStart ? "START" : "END"} marker");

    // Try adding the sphere node via fallback
    final node = await _addNodeWithFallback(
      name: isStart ? "start_marker" : "end_marker",
      transform: transform,
      scale: markerScale,
    );

    if (node != null) {
      anchorNodes.add(node);
    } else {
      debugPrint("❌ FAILED to add marker node");
    }

    // If both points exist → measure and draw dotted line
    if (anchors.length == 2) {
      _updateDistance();
      await _drawDottedLine();
    } else {
      setState(() => measuredMeters = 0.0);
    }
  }

  // Remove oldest anchor and node
  Future<void> _removeOldestAnchor() async {
    if (anchors.isNotEmpty) {
      final oldAnchor = anchors.removeAt(0);
      try {
        await arAnchorManager?.removeAnchor(oldAnchor);
      } catch (_) {}
    }

    if (anchorNodes.isNotEmpty) {
      final oldNode = anchorNodes.removeAt(0);
      try {
        await arObjectManager?.removeNode(oldNode);
      } catch (_) {}
    }

    // Remove old dotted line
    for (final n in lineNodes) {
      try {
        await arObjectManager?.removeNode(n);
      } catch (_) {}
    }
    lineNodes.clear();
  }

  // Extract Vector3 position from transform
  Vector3 _posFromTransform(dynamic t) {
    try {
      if (t is Matrix4) {
        final s = t.storage;
        return Vector3(s[12], s[13], s[14]);
      }
      if (t is List && t.length >= 16) {
        return Vector3(
          t[12].toDouble(),
          t[13].toDouble(),
          t[14].toDouble(),
        );
      }
    } catch (_) {}
    return Vector3.zero();
  }

  // Measure distance between two anchors
  void _updateDistance() {
    if (anchors.length < 2) return;

    final p1 = _posFromTransform(anchors[0].transformation);
    final p2 = _posFromTransform(anchors[1].transformation);

    final dx = p1.x - p2.x;
    final dy = p1.y - p2.y;
    final dz = p1.z - p2.z;

    final meters = sqrt(dx * dx + dy * dy + dz * dz);

    setState(() => measuredMeters = meters);

    debugPrint("Distance: $meters meters");
  }

  // Draw dotted line between two anchors
  Future<void> _drawDottedLine() async {
    for (final n in lineNodes) {
      try {
        await arObjectManager?.removeNode(n);
      } catch (_) {}
    }
    lineNodes.clear();

    if (anchors.length < 2) return;

    final p1 = _posFromTransform(anchors[0].transformation);
    final p2 = _posFromTransform(anchors[1].transformation);

    for (int i = 1; i <= lineDots; i++) {
      final t = i / (lineDots + 1);
      final pos = Vector3(
        p1.x + (p2.x - p1.x) * t,
        p1.y + (p2.y - p1.y) * t,
        p1.z + (p2.z - p1.z) * t,
      );

      final transform = Matrix4.identity()..setTranslation(pos);

      final node = await _addNodeWithFallback(
        name: "dot_$i",
        transform: transform,
        scale: dotScale,
      );

      if (node != null) {
        lineNodes.add(node);
      }
    }
  }

  // Reset everything
  Future<void> _resetAll() async {
    for (final n in lineNodes) {
      try {
        await arObjectManager?.removeNode(n);
      } catch (_) {}
    }
    lineNodes.clear();

    for (final n in anchorNodes) {
      try {
        await arObjectManager?.removeNode(n);
      } catch (_) {}
    }
    anchorNodes.clear();

    for (final a in List<ARAnchor>.from(anchors)) {
      try {
        await arAnchorManager?.removeAnchor(a);
      } catch (_) {}
    }
    anchors.clear();

    setState(() => measuredMeters = 0.0);
  }

  // =====================
  // === PART 3 START ====
  // =====================

  // Format distance nicely
  String _formattedDistance() {
    if (measuredMeters >= 1.0) return '${measuredMeters.toStringAsFixed(2)} m';
    return '${(measuredMeters * 100).toStringAsFixed(1)} cm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Measure (fallback loader)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetAll,
            tooltip: 'Reset',
          ),
        ],
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                anchors.length >= 2
                    ? 'Distance: ${_formattedDistance()}'
                    : 'Tap two points to measure',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
