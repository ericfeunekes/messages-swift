# Third-party notices

## openclaw/imsg

`Sources/MessagesCore/TypedStreamParser.swift` and
`Tests/MessagesCoreTests/TypedStreamParserTests.swift` adapt the public
[openclaw/imsg](https://github.com/openclaw/imsg) source at commit
`1db058697a1f6705d907516e668acf2e25ab57d8`.

The parser preserves upstream length framing, archive byte order, and leading
control-scalar trimming. This adaptation returns an optional string and rejects
invalid raw UTF-8, distinguishing failure from a successfully decoded empty body.
The upstream rejection assertions consequently expect `nil`; successful decoding
assertions and fixture bytes are retained. The big-endian fixture expression is
split into typed appends for Swift 6.1 compiler tractability without changing bytes.

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
