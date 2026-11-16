# Third-party notices

Brain Input is licensed under the GNU General Public License v3.0 (see `LICENSE`). It contains or uses the following work by others.

## Code adapted into this repository

**VoiceInk** · https://github.com/Beingpax/VoiceInk · GPL-3.0
- `Sources/BrainWhisper/WhisperTranscriber.swift`: whisper context handling, adapted from `LibWhisper.swift`.
- `Sources/BrainInputApp/System.swift` (`ClipboardPaster`): clipboard snapshot and restore, transient pasteboard markers and the ⌘V event, adapted from `CursorPaster.swift` and `ClipboardManager.swift`.

## Libraries shipped inside the app

**whisper.cpp** · https://github.com/ggml-org/whisper.cpp · MIT

> Copyright (c) 2023-2026 The ggml authors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

**FluidAudio** · https://github.com/FluidInference/FluidAudio · Apache License 2.0
Copyright the FluidInference team. The licence text is at https://www.apache.org/licenses/LICENSE-2.0; FluidAudio's own third-party licences are in its repository under `ThirdPartyLicenses/`.

## Speech models (downloaded by the user, not shipped with the app)

**Parakeet TDT 0.6B v3** · NVIDIA · https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 · CC-BY-4.0
Core ML conversion by FluidInference: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml

**Whisper large-v3 turbo** · OpenAI · https://github.com/openai/whisper · MIT
ggml conversion from https://huggingface.co/ggerganov/whisper.cpp

## Services

Text clean-up, style notes and meeting summaries use the Claude API by Anthropic when the user supplies their own API key. "Claude" and "Anthropic" are trademarks of Anthropic, PBC. Brain Input is an independent project and is not affiliated with or endorsed by Anthropic, NVIDIA, OpenAI, VoiceInk or Monologue.
