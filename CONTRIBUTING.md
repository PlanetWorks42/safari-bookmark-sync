# Contributing / 贡献说明

V0.9 is the first public preview. Bug reports and contributions are welcome.

- Run `zsh test-favorites.sh` and `zsh build.sh` before proposing changes.
- Use synthetic bookmark fixtures, never real browser profiles or backups.
- Add both English and Simplified Chinese resources for user-visible text. Preserve positional `%1$@` parameters and run `python3 Scripts/check-localizations.py`.
- Keep browser-running guards, backup verification, profile checks, and rollback behavior intact.
- For UI changes, check both languages, light/dark appearance, minimum size, scrolling, and the menu bar fallback.
- Keep generated files, local installers, credentials, user paths, and diagnostics out of commits. `dist/` is intentionally ignored.

V0.9 为首个公开预览版本，欢迎反馈和贡献。修改前运行测试和构建；只使用模拟书签；界面文字同时补齐中英文资源。不要上传真实书签、备份或机器诊断，不要移除备份和写入保护。
