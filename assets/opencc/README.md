# Chinese script conversion

`TSCharacters.txt` and `TSPhrases.txt` are unchanged OpenCC `ver.1.1.9` dictionaries:
https://github.com/BYVoid/OpenCC/tree/ver.1.1.9/data/dictionary

Distributed under the included Apache 2.0 [LICENSE](LICENSE).
Android uses longest dictionary matching with phrase precedence, matching the
dictionary group in OpenCC's `t2s.json`. This only converts script; it does not
rewrite regional terms or perform language-model inference. Windows retains its
existing `LCMapStringEx` conversion.
