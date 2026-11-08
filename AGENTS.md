# AGENTS.md

このファイルは、このリポジトリで動くAIコーディングエージェント（Claude Code、OpenAI Codexなど）が共通で参照する**禁止事項と最低限のチェック**を集めた索引である。

- **Claude Code**：ルートの`CLAUDE.md`が`@AGENTS.md`で取り込む
- **OpenAI Codex**：ルートの`AGENTS.md`を直接読み込む

本ファイルは、AIが**コードを書く・直す・出す**ときに踏み外してはいけない事項に絞る。

## プロジェクト概要

`README.md`を参照（技術スタック・ディレクトリ構成）。

## コマンド

リポジトリのルートで実行する。Xcode（Swift 6 以降）が必要。

| 用途 | コマンド |
|---|---|
| テスト | `swift test` |
| ビルド | `swift build` |
| アプリのバンドルを作る | `./scripts/build-app.sh`（`build/Break Trigger.app` ができる） |
| 起動 | `open "build/Break Trigger.app"` |
| 時間を縮めて起動（動作確認用） | `BREAK_TRIGGER_TIME_SCALE=60 "build/Break Trigger.app/Contents/MacOS/BreakTrigger"` |

通知はアプリのバンドルからしか出せないため、`swift run` では通知の確認ができない。

## git操作

**gitを操作しない**。次の操作は、すべて人間が行う。人間が明示的に依頼したときだけ実行する。

- ブランチの作成・切り替え
- `add`、`commit`、`push`、`merge`、`rebase`、`reset`、`stash`
- PRの作成

コードの変更は、作業ツリーに残すところまでで止める。状態を確認する読み取り専用のコマンド（`git status`、`git log`、`git diff`など）は実行してよい。

## ドキュメントとコードの食い違い

**ドキュメントと既存のコードが食い違うときは、コードの書き方に従う**。READMEや注記の説明が古いまま残っていることがあるため、動いているコードを正とする。

見つけた食い違いは、その場で黙って直さず、作業の最後の返答ですべて挙げる。ドキュメントを直すかどうかは、人間が決める。

## 規約

- **コミットメッセージ**：日本語。1行目に`feat:`などの種別prefixを付ける（`feat`、`fix`、`refactor`、`perf`、`chore`、`docs`、`test`、`ci`）。
- **Issue**：タイトルに種別prefixを付ける。本文は`.github/ISSUE_TEMPLATE/`のテンプレート（`機能追加.md`か`バグ修正.md`）を選び、その見出し構成のまま全項目を埋める。調査タスクは`機能追加.md`を使う。
- **PR**：`.github/pull_request_template.md`の見出し構成のまま全項目を埋める。
- **コードのコメント・ドキュメント文字列**：日本語で書く。
