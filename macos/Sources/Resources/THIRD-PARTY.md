# Third-party data

## english-ipa.txt

Derived from **[ipa-dict](https://github.com/open-dict-data/ipa-dict)** (`data/en_US.txt`),
a word→IPA pronunciation list, © 2016 dohliam, released under the MIT License.

Regenerate with `scripts/gen-ipa-dict.sh` (pinned to ipa-dict commit
`43c3570eb3553bdd19fccd2bd0091534889af023`). The preprocessing keeps the first
pronunciation, strips the surrounding slashes, normalizes the velarized `ɫ` to
`l`, and lowercases the headword. No other modifications.

### License

```
The MIT License (MIT)

Copyright (c) 2016 dohliam

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
```
