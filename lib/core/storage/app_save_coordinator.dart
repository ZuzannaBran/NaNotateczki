import 'dart:async';

class AppSaveCoordinator {
  AppSaveCoordinator._();

  static final AppSaveCoordinator instance = AppSaveCoordinator._();

  final Map<Object, _SaveParticipant> _participants =
      <Object, _SaveParticipant>{};

  bool get hasPendingWork {
    for (final participant in _participants.values) {
      if (participant.hasPendingWork()) {
        return true;
      }
    }
    return false;
  }

  void register(
    Object owner, {
    required bool Function() hasPendingWork,
    required Future<void> Function() flush,
  }) {
    _participants[owner] = _SaveParticipant(
      hasPendingWork: hasPendingWork,
      flush: flush,
    );
  }

  void unregister(Object owner) {
    _participants.remove(owner);
  }

  Future<void> flushPending() async {
    final participants = List<_SaveParticipant>.from(_participants.values);
    for (final participant in participants) {
      if (participant.hasPendingWork()) {
        await participant.flush();
      }
    }
  }
}

class _SaveParticipant {
  const _SaveParticipant({required this.hasPendingWork, required this.flush});

  final bool Function() hasPendingWork;
  final Future<void> Function() flush;
}
