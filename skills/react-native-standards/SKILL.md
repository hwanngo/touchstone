---
name: react-native-standards
description: Use when building a React Native / Expo mobile app in a touchstone repo — Expo + EAS, the New Architecture, navigation, lists, native modules, OTA updates, mobile security. Triggers on `react-native`/`expo` in package.json, app.json/eas.json, .tsx mobile screens. For web React (DOM/Vite/Next) use the react skill; language rules live in the typescript skill.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# React Native (framework)

Full standard: **`standards/frameworks/react-native.md`** (layers on `frameworks/react.md` +
`languages/typescript.md`). The react.md state/component/forms rules still hold; this covers what's
native. Load-bearing rules:

## Always
- **Expo managed workflow + EAS** (Build/Update/Submit). Native projects are generated from
  `app.json` + config plugins — never hand-edit `ios/`/`android/`. Bare/dev-client is the escape
  hatch, not the default.
- **New Architecture only** (Fabric + TurboModules + JSI, Hermes engine). Vet every native dep for
  New-Arch support; no legacy bridge modules.
- **Server state = TanStack Query** (persisted to MMKV, offline-tolerant, Zod-validated, timeout-bounded);
  client state = `useState`/Zustand — same split as react.md. Forms = React Hook Form + Zod.
- **Expo Router** (file-based, typed routes) for navigation; FlashList over FlatList for lists;
  `expo-image` for cached remote images.

## Don't get burned
- **The JS bundle is public** — no secrets/API keys/private endpoints in it. Credentials only in
  **`expo-secure-store`** (Keychain/Keystore), never AsyncStorage/MMKV.
- **OTA (EAS Update) ships JS only** — native changes (new permission, SDK bump, plugin) need a new
  EAS Build; pin `runtimeVersion` so updates land only on compatible binaries.
- **Permissions just-in-time** with usage strings via config plugins; profile lists on a low-end
  physical Android; respect safe areas and test both platforms.

## Done
`biome ci` · `tsc` · Jest+RNTL · `expo-doctor` clean; New Arch; FlashList; no secrets in bundle;
`runtimeVersion` pinned; Maestro/Detox + a11y (VoiceOver/TalkBack) on critical flows. See
`standards/frameworks/react-native.md`.
