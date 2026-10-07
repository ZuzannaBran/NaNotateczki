import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';

enum ObjectTransformKind { move, resize, rotate }

class ObjectTransformSnapshot {
  const ObjectTransformSnapshot({
    required this.kind,
    required this.rect,
    required this.rotation,
    this.handle,
    this.resizeMode,
  });

  final ObjectTransformKind kind;
  final Rect rect;
  final double rotation;
  final HandlePosition? handle;
  final ResizeMode? resizeMode;
}

class ObjectTransformEngine {
  _ObjectTransformSession? _session;
  ObjectTransformSnapshot? _lastPreview;

  bool get isActive => _session != null;

  ObjectTransformKind? get kind => _session?.kind;

  void beginMove({
    required Rect rect,
    required double rotation,
    required Offset pointer,
    Rect clampingRect = Rect.largest,
    BindingStrategy bindingStrategy = BindingStrategy.originalBox,
  }) {
    _begin(
      _ObjectTransformSession(
        kind: ObjectTransformKind.move,
        initialRect: rect,
        initialRotation: rotation,
        pointerStart: pointer,
        clampingRect: clampingRect,
        bindingStrategy: bindingStrategy,
      ),
    );
  }

  void beginResize({
    required Rect rect,
    required double rotation,
    required Offset pointer,
    required HandlePosition handle,
    required ResizeMode resizeMode,
    BoxConstraints constraints = const BoxConstraints(),
    Rect clampingRect = Rect.largest,
    BindingStrategy bindingStrategy = BindingStrategy.originalBox,
  }) {
    _begin(
      _ObjectTransformSession(
        kind: ObjectTransformKind.resize,
        initialRect: rect,
        initialRotation: rotation,
        pointerStart: pointer,
        handle: handle,
        resizeMode: resizeMode,
        constraints: constraints,
        clampingRect: clampingRect,
        bindingStrategy: bindingStrategy,
      ),
    );
  }

  void beginRotate({
    required Rect rect,
    required double rotation,
    required Offset pointer,
    Rect clampingRect = Rect.largest,
    BindingStrategy bindingStrategy = BindingStrategy.originalBox,
  }) {
    _begin(
      _ObjectTransformSession(
        kind: ObjectTransformKind.rotate,
        initialRect: rect,
        initialRotation: rotation,
        pointerStart: pointer,
        clampingRect: clampingRect,
        bindingStrategy: bindingStrategy,
      ),
    );
  }

  ObjectTransformSnapshot update(Offset pointer, {bool snapRotation = false}) {
    final session = _session;
    if (session == null) {
      throw StateError('ObjectTransformEngine.update called without begin');
    }

    final preview = switch (session.kind) {
      ObjectTransformKind.move => _move(session, pointer),
      ObjectTransformKind.resize => _resize(session, pointer),
      ObjectTransformKind.rotate => _rotate(
        session,
        pointer,
        snapRotation: snapRotation,
      ),
    };
    _lastPreview = preview;
    return preview;
  }

  ObjectTransformSnapshot? end() {
    final result = _lastPreview;
    _session = null;
    _lastPreview = null;
    return result;
  }

  void cancel() {
    _session = null;
    _lastPreview = null;
  }

  void _begin(_ObjectTransformSession session) {
    _session = session;
    _lastPreview = ObjectTransformSnapshot(
      kind: session.kind,
      rect: session.initialRect,
      rotation: session.initialRotation,
      handle: session.handle,
      resizeMode: session.resizeMode,
    );
  }

  ObjectTransformSnapshot _move(
    _ObjectTransformSession session,
    Offset pointer,
  ) {
    final result = UIBoxTransform.move(
      initialRect: session.initialRect,
      initialLocalPosition: session.pointerStart,
      localPosition: pointer,
      clampingRect: session.clampingRect,
      rotation: session.initialRotation,
      bindingStrategy: session.bindingStrategy,
    );
    return ObjectTransformSnapshot(
      kind: ObjectTransformKind.move,
      rect: result.rect,
      rotation: result.rotation,
    );
  }

  ObjectTransformSnapshot _resize(
    _ObjectTransformSession session,
    Offset pointer,
  ) {
    final result = UIBoxTransform.resize(
      initialRect: session.initialRect,
      initialLocalPosition: session.pointerStart,
      localPosition: pointer,
      handle: session.handle!,
      resizeMode: session.resizeMode!,
      initialFlip: Flip.none,
      clampingRect: session.clampingRect,
      constraints: session.constraints,
      allowFlipping: false,
      rotation: session.initialRotation,
      bindingStrategy: session.bindingStrategy,
    );
    if (!result.feasible && _lastPreview != null) {
      return _lastPreview!;
    }
    return ObjectTransformSnapshot(
      kind: ObjectTransformKind.resize,
      rect: result.rect,
      rotation: result.rotation,
      handle: session.handle,
      resizeMode: session.resizeMode,
    );
  }

  ObjectTransformSnapshot _rotate(
    _ObjectTransformSession session,
    Offset pointer, {
    required bool snapRotation,
  }) {
    final result = UIBoxTransform.rotate(
      initialRect: session.initialRect,
      initialLocalPosition: session.pointerStart,
      localPosition: pointer,
      initialRotation: session.initialRotation,
      clampingRect: session.clampingRect,
      bindingStrategy: session.bindingStrategy,
    );
    if (!result.feasible && _lastPreview != null) {
      return _lastPreview!;
    }
    var rotation = result.rotation;
    if (snapRotation) {
      const snap = math.pi / 12;
      rotation = (rotation / snap).round() * snap;
    }
    return ObjectTransformSnapshot(
      kind: ObjectTransformKind.rotate,
      rect: result.rect,
      rotation: rotation,
    );
  }
}

class _ObjectTransformSession {
  const _ObjectTransformSession({
    required this.kind,
    required this.initialRect,
    required this.initialRotation,
    required this.pointerStart,
    this.handle,
    this.resizeMode,
    this.constraints = const BoxConstraints(),
    this.clampingRect = Rect.largest,
    this.bindingStrategy = BindingStrategy.originalBox,
  });

  final ObjectTransformKind kind;
  final Rect initialRect;
  final double initialRotation;
  final Offset pointerStart;
  final HandlePosition? handle;
  final ResizeMode? resizeMode;
  final BoxConstraints constraints;
  final Rect clampingRect;
  final BindingStrategy bindingStrategy;
}
