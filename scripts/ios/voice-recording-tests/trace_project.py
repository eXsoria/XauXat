"""Add observations to generated copies; do not rewrite production files."""
def once(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new, 1)


def after(text, signature, code):
    return once(text, signature, signature + '\n' + code)


def instrument(editor, harness, tests, trace):
    for method in ('beginVoiceMessageRecording', 'releaseVoiceMessageRecording', 'cancelVoiceMessageTouch',
                   'discardVoiceMessageRecording', 'startVoiceMessageRecording', 'finishVoiceMessageRecording',
                   'resumeVoiceMessageRecording', 'cancelCurrentVoiceRecording'):
        start = editor.index('func ' + method + '(')
        brace = editor.index('{', start)
        code = f'\n        traceVoiceState("controller.{method}.enter")\n        defer {{ traceVoiceState("controller.{method}.exit") }}\n'
        editor = editor[:brace + 1] + code + editor[brace + 1:]
    editor = once(editor,
        '        guard voiceInteraction.requestID == requestID else {\n            recorder.stop()',
        '        traceVoice("controller.start.result", ["request": requestID.uuidString, "error": String(describing: recStartError)])\n'
        '        traceVoiceState("controller.start.result.state")\n'
        '        guard voiceInteraction.requestID == requestID else {\n            recorder.stop()')
    editor = after(editor, '                if recorder.duration < VoiceRecordingInteraction.minimumRecordingDuration {',
                   '                    traceVoice("controller.discard.shortCapture", ["duration": String(recorder.duration)])')
    editor = once(editor,
        '        switch voiceInteraction.release(touch: touch) {',
        '        let traceReadyAt = voiceInteraction.readyAt\n'
        '        let releaseAction = voiceInteraction.release(touch: touch)\n'
        '        traceVoice("controller.release.action", [\n'
        '            "action": String(describing: releaseAction),\n'
        '            "beganAt": String(touch.beganAt), "endedAt": String(touch.endedAt),\n'
        '            "readyAt": traceReadyAt.map { String($0) } ?? "none",\n'
        '            "physicalDuration": String(touch.endedAt - touch.beganAt),\n'
        '            "usefulDuration": traceReadyAt.map { String(touch.endedAt - max(touch.beganAt, $0)) } ?? "none"\n'
        '        ])\n'
        '        switch releaseAction {')
    # Prefix exact signatures, including the default closure in start().
    signatures = {
        'start': '    func start(fileName: String, shouldStart: () -> Bool = { true }) async -> StartError? {',
        'startSegment': '    private func startSegment(_ fileName: String) throws {',
        'pause': '    func pause() -> Task<Void, Error> {',
        'resume': '    func resume() -> Bool {',
        'closeSegment': '    private func closeSegment() {',
        'checkPermission': '    private func checkPermission() async -> Bool {',
    }
    for name, signature in signatures.items():
        editor = after(editor, signature,
            f'        traceVoiceAudio("audio.{name}.enter")\n        defer {{ traceVoiceAudio("audio.{name}.exit") }}')
    editor = after(editor, '        let allowed = await checkPermission()',
                   '        traceVoice("audio.permission.result", ["allowed": String(allowed), "taskCancelled": String(Task.isCancelled)])')
    editor = once(editor,
        '        let av = AVAudioSession.sharedInstance()\n        try av.setCategory(.playAndRecord, options: .defaultToSpeaker)\n        ownsAudioSession = true\n        try av.setActive(true)',
        '        traceVoice("audio.session.instance.begin")\n'
        '        let traceInstanceAt = ProcessInfo.processInfo.systemUptime\n'
        '        let av = AVAudioSession.sharedInstance()\n'
        '        traceVoice("audio.session.instance.end", ["elapsed": String(ProcessInfo.processInfo.systemUptime - traceInstanceAt)])\n'
        '        traceVoice("audio.session.category.begin")\n'
        '        let traceCategoryAt = ProcessInfo.processInfo.systemUptime\n'
        '        try av.setCategory(.playAndRecord, options: .defaultToSpeaker)\n'
        '        traceVoice("audio.session.category.end", ["elapsed": String(ProcessInfo.processInfo.systemUptime - traceCategoryAt)])\n'
        '        ownsAudioSession = true\n'
        '        traceVoice("audio.session.activation.begin")\n'
        '        let traceActivationAt = ProcessInfo.processInfo.systemUptime\n'
        '        try av.setActive(true)')
    editor = once(editor, '        switch av.recordPermission {',
        '        traceVoice("audio.permission.status.begin")\n'
        '        let tracePermissionAt = ProcessInfo.processInfo.systemUptime\n'
        '        let tracePermission = av.recordPermission\n'
        '        traceVoice("audio.permission.status", ["status": String(describing: tracePermission), "elapsed": String(ProcessInfo.processInfo.systemUptime - tracePermissionAt)])\n'
        '        switch tracePermission {')
    editor = once(editor,
        '        let av = AVAudioSession.sharedInstance()\n        traceVoice("audio.permission.status.begin")',
        '        traceVoice("audio.permission.session.begin")\n'
        '        let tracePermissionInstanceAt = ProcessInfo.processInfo.systemUptime\n'
        '        let av = AVAudioSession.sharedInstance()\n'
        '        traceVoice("audio.permission.session.end", ["elapsed": String(ProcessInfo.processInfo.systemUptime - tracePermissionInstanceAt)])\n'
        '        traceVoice("audio.permission.status.begin")')
    editor = once(editor,
        '        let recorder = try AVAudioRecorder(url: getAppFilePath(fileName), settings: settings)',
        '        traceVoice("audio.recorder.init.begin")\n'
        '        let traceRecorderInitAt = ProcessInfo.processInfo.systemUptime\n'
        '        let recorder = try AVAudioRecorder(url: getAppFilePath(fileName), settings: settings)\n'
        '        traceVoice("audio.recorder.init.end", ["elapsed": String(ProcessInfo.processInfo.systemUptime - traceRecorderInitAt)])')
    editor = once(editor,
        '        guard recorder.record(forDuration: MAX_VOICE_MESSAGE_LENGTH - duration) else { throw RecordingError.unavailable }',
        '        traceVoice("audio.recorder.record.begin")\n'
        '        let traceRecordAt = ProcessInfo.processInfo.systemUptime\n'
        '        let traceDidRecord = recorder.record(forDuration: MAX_VOICE_MESSAGE_LENGTH - duration)\n'
        '        traceVoice("audio.recorder.record.result", ["started": String(traceDidRecord), "elapsed": String(ProcessInfo.processInfo.systemUptime - traceRecordAt)])\n'
        '        guard traceDidRecord else { throw RecordingError.unavailable }')
    editor = after(editor, '        try av.setActive(true)',
                   '        traceVoice("audio.session.active", ["elapsed": String(ProcessInfo.processInfo.systemUptime - traceActivationAt)])')
    editor = once(editor, '        } catch {\n            stop()\n            logger.error',
                  '        } catch {\n            traceVoiceError("audio.start.error", error)\n            stop()\n            logger.error')
    for name, signature, detail in (
        ('began', '        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {', ''),
        ('ended', '        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {', ''),
        ('cancelled', '        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {', ''),
    ):
        editor = after(editor, signature, f'''            traceVoice("touch.{name}", [
                "view": String(describing: ObjectIdentifier(self)),
                "enabled": String(actions?.enabled == true), "origin": String(describing: origin),
                "touchTime": String(touches.first?.timestamp ?? -1),
                "beganAt": beganAt.map {{ String($0) }} ?? "none",
                "point": String(describing: touches.first?.location(in: window)),
                "frame": String(describing: convert(bounds, to: window)), "hasWindow": String(window != nil)
            ])''')
    editor = after(editor, '        override func accessibilityActivate() -> Bool {',
                   '            traceVoice("touch.accessibilityActivate", ["view": String(describing: ObjectIdentifier(self)), "enabled": String(actions?.enabled == true)])')
    editor = once(editor, '        override func accessibilityActivate() -> Bool {', '''        override func didMoveToWindow() {
            super.didMoveToWindow()
            traceVoice("touch.window", ["view": String(describing: ObjectIdentifier(self)), "hasWindow": String(window != nil), "frame": String(describing: convert(bounds, to: window))])
        }

        override func accessibilityActivate() -> Bool {''')
    editor = after(editor, '    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {',
                   '        traceVoice("audio.delegate.finished", ["success": String(flag), "recorder": String(describing: ObjectIdentifier(recorder))])')
    editor = after(editor, '    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {',
                   '        if let error { traceVoiceError("audio.delegate.encodeError", error) }')
    harness = once(harness, '        .padding()\n        .onChange(of: composeState.voiceMessageRecordingState)',
                   '        .padding()\n        .onAppear { traceVoiceState("harness.appear") }\n        .onChange(of: composeState.voiceMessageRecordingState)')
    harness = after(harness, '        .onChange(of: scenePhase) { phase in',
                    '            traceVoiceState("harness.scene.changed")')
    tests = after(tests, '        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]',
                  '        app.launchArguments += ["--voice-ci-case", name]')
    return editor + '\n' + trace, harness, tests
