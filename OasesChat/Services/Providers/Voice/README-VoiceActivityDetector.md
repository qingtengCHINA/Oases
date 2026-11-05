# VoiceActivityDetector

Uses Swift package **RealTimeCutVADLibrary** (Silero VAD v5 + WebRTC APM):

```
https://github.com/helloooideeeeea/RealTimeCutVADLibrary.git  (from: 1.0.0)
```

`project.yml` points at the remote package. Offline / resolve failures: flip the
package entry back to the energy-based stub:

```yaml
RealTimeCutVADLibrary:
  path: vendor/spm/RealTimeCutVADStub
```

The stub implements the same `VADWrapper` / `VADDelegate` surface so
`VoiceActivityDetector.swift` compiles either way.
