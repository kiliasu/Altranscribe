# Font assets

- `RobotoFlex.ttf`: Latin variable font, converted from WOFF2 to TTF with variable axes and copyright metadata retained. Licensed under SIL OFL 1.1.
- `MaterialSymbolsRounded.ttf`: 54-icon subset converted from WOFF2 to TTF; outlines are unchanged. Licensed under Apache 2.0.
- `Roboto-*.ttf` and `NotoSansSC-*.ttf`: text fonts; Noto Sans SC supplies Chinese glyphs. Their license files are included alongside the fonts.

The converted fonts and icon subset are modified files, not unmodified upstream downloads. `RobotoFlex-LICENSE.txt` and `MaterialSymbolsRounded-LICENSE.txt` preserve the copyright metadata of the converted files; `RobotoFlex-OFL.txt`, `MaterialSymbolsRounded-APACHE.txt`, `Roboto-LICENSE.txt` and `NotoSansSC-OFL.txt` are the full license texts.

Material Symbols maps U+E663 to `auto_fix`; `lib/shared/ui/alt_icons.dart` uses this code point for `autoFixHigh`.

Upstream: [Roboto Flex](https://github.com/googlefonts/roboto-flex), [Material Design Icons](https://github.com/google/material-design-icons), [Roboto](https://fonts.google.com/specimen/Roboto) and [Noto Sans SC](https://fonts.google.com/noto/specimen/Noto+Sans+SC) on Google Fonts.
