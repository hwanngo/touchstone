# Angular Standards

Framework layer; language rules → [typescript.md](../languages/typescript.md). This doc owns
modern **Angular (v18/19+)** — standalone, signals, and signals-first state — and defers a11y to
[accessibility.md](../practices/accessibility.md), test philosophy to
[testing-strategy.md](../practices/testing-strategy.md), HTTP contracts to
[api-design.md](../design/api-design.md), and the secret boundary to
[security.md](../practices/security.md).

> **One law:** standalone + signals + `OnPush` is the baseline — NgModules, Zone.js change
> detection, and manual `subscribe()` are legacy you migrate off, not patterns you reach for.

---

## 1. Standalone is the default (no NgModules)

- **`standalone: true` is implicit in v19+** — every component/directive/pipe declares its own
  `imports`. **Do not author new `NgModule`s.** Run `ng generate @angular/core:standalone` to
  migrate a legacy app in three passes (imports → bootstrap → prune modules).
- **Bootstrap with `bootstrapApplication`** and compose features through `ApplicationConfig`
  provider functions — `provideRouter`, `provideHttpClient`, `provideAnimationsAsync` — never the
  `BrowserModule`/`HttpClientModule` era.
- **One concern per component.** A component owns its template, its signals, and its local
  presentation; lift shared logic into a service or a function, not a base class.

```ts
bootstrapApplication(AppComponent, {
  providers: [
    provideRouter(routes, withComponentInputBinding()),
    provideHttpClient(withInterceptors([authInterceptor, errorInterceptor])),
  ],
})
```

## 2. Signals are the reactive primitive

- **`signal()` for writable state, `computed()` for derived state, `effect()` only for side
  effects** (sync to DOM/storage/logging). A `computed` that returns a value must never mutate —
  derived state belongs in `computed`, not `effect`. Effects are not a `watch` for triggering
  writes; that re-introduces glitches `computed` exists to prevent.
- **Set, don't mutate.** `count.set(n)` / `count.update(c => c + 1)`; for objects produce a new
  reference. Signals use referential equality — in-place mutation won't notify.
- **Signal-based component API** replaces decorators end to end:

| Old decorator | Signal API | Note |
|---|---|---|
| `@Input()` | `input<T>()` / `input.required<T>()` | read-only signal; `transform` supported |
| `@Output()` | `output<T>()` | no more `EventEmitter` import |
| `@ViewChild` | `viewChild()` / `viewChild.required()` | resolves as a signal, no lifecycle race |
| `@ContentChild` | `contentChild()` | same |
| two-way `@Input/@Output` | `model<T>()` | one declaration for `[(x)]` |

```ts
@Component({ selector: 'app-counter', changeDetection: ChangeDetectionStrategy.OnPush, template: `…` })
export class CounterComponent {
  readonly start = input.required<number>()
  readonly delta = input(1)
  readonly changed = output<number>()
  protected readonly count = signal(0)
  protected readonly total = computed(() => this.start() + this.count())
}
```

## 3. Change detection: `OnPush` + signals, Zoneless where viable

- **`ChangeDetectionStrategy.OnPush` on every component** — set it in the `ng new` schematic so
  it's the default. Signals mark only their own consumers dirty, so `OnPush` + signals gives
  precise, local re-render without manual `markForCheck()`.
- **Go zoneless** on new apps — `provideZonelessChangeDetection()` (stable in v20) and drop
  `zone.js` from `polyfills`. Signals, `AsyncPipe`, and template events drive detection; nothing
  relies on Zone monkey-patching `setTimeout`/`fetch`. _(scale-up: audit third-party libs that
  assume Zone before flipping a large existing app.)_
- **Never call `detectChanges()` / `ApplicationRef.tick()` to "fix" a view.** A view that won't
  update is state held outside a signal — move it into one.

## 4. Dependency injection: `inject()` and `providedIn`

- **`inject()` over constructor parameters** — works in functions (guards, resolvers,
  interceptors), composes into reusable helpers, and sidesteps the inheritance constructor-super
  boilerplate. Constructor injection stays valid but `inject()` is the house default.
- **`providedIn: 'root'` for singletons** so they tree-shake when unused — prefer it to listing a
  service in a providers array. Scope a service to a route or component only when you genuinely
  want a fresh instance per subtree.
- **`InjectionToken<T>` for non-class dependencies** (config objects, feature flags) — typed, no
  string keys. Don't inject concrete config classes you could express as a token.

```ts
export const authGuard: CanActivateFn = () => {
  const auth = inject(AuthService)
  return auth.isLoggedIn() ? true : inject(Router).createUrlTree(['/login'])
}
```

## 5. Routing: lazy standalone routes + functional guards

- **Lazy-load every feature** with `loadComponent` (one component) or `loadChildren` (a route
  subtree returning a `Routes` array) — never eager-import a feature's components into the root.
- **Functional `CanActivateFn` / `ResolveFn` / `CanMatchFn`** — class-based guards are
  deprecated. Use `CanMatchFn` to gate *whether a lazy chunk loads at all* (auth, feature flags),
  not just whether you can navigate.
- **Route-level `providers`** scope services to a feature subtree; **`withComponentInputBinding()`**
  binds route params/query/data straight to signal `input()`s — no manual `ActivatedRoute`
  plumbing for the common case.

```ts
export const routes: Routes = [
  {
    path: 'orders',
    canMatch: [authGuard],
    providers: [OrdersStore],
    loadChildren: () => import('./orders/orders.routes').then(m => m.ORDERS_ROUTES),
  },
]
```

## 6. RxJS vs signals — and no leaked subscriptions

- **Signals for state, RxJS for events and async streams.** Signals model "the current value";
  RxJS still owns coordination over time — debounced typeahead, websockets/SSE, retry/backoff,
  combining racing requests. Don't rebuild `switchMap` cancellation by hand in an `effect`.
- **Bridge at the edges:** `toSignal(obs$)` to consume a stream in a template (auto-unsubscribes);
  `toObservable(sig)` when an operator pipeline needs a signal as its source.
- **Never bare-`subscribe()` without teardown.** Prefer the `AsyncPipe`/`toSignal` in templates;
  where you must subscribe imperatively, end the pipe with **`takeUntilDestroyed()`** so it
  disposes with the component. A manual subscription with no teardown is a memory leak by default.

```ts
this.query$.pipe(
  debounceTime(250),
  switchMap(q => this.api.search(q)),   // cancels the in-flight request
  takeUntilDestroyed(),
).subscribe(/* … */)
```

## 7. Forms: typed reactive over template-driven

- **Typed Reactive Forms** (`FormGroup`/`FormControl` with strict types, or `NonNullableFormBuilder`)
  for anything non-trivial — validation lives in code, is unit-testable, and the value is typed.
  Template-driven `ngModel` is fine only for a one-off toggle.
- **`nonNullable: true`** so `reset()` restores the initial value rather than `null`, and the
  control type is `T` not `T | null`.
- **Validate the submitted value through the same Zod schema as the API boundary** (§8,
  [typescript.md](../languages/typescript.md) §7) so client and server agree by construction;
  cross-field rules go in a group-level validator, not scattered `effect`s.

## 8. HTTP: typed `HttpClient` + functional interceptors

- **`provideHttpClient(withInterceptors([...]))`** with **functional interceptors** (`HttpInterceptorFn`)
  — auth headers, correlation IDs, error mapping, retry. Class-based interceptors are legacy.
- **Type responses, then parse at the boundary.** `http.get<unknown>()` then Zod-`parse` into the
  domain type — never trust the server's shape via a bare generic that the compiler can't verify.
  See [api-design.md](../design/api-design.md) for the shared contract.
- **`httpResource()`** (v19+) for declarative, signal-driven reads that track a reactive URL and
  expose `value`/`status`/`error` signals; keep imperative `firstValueFrom`/`subscribe` for
  commands (POST/PUT/DELETE). Thread timeouts/cancellation per [typescript.md](../languages/typescript.md) §9.

## 9. Control flow & deferred loading

- **Built-in `@if` / `@for` / `@switch`** — the structural-directive forms (`*ngIf`, `*ngFor`,
  `*ngSwitch`) are superseded; migrate with `ng generate @angular/core:control-flow`.
- **`@for` requires `track`** — track by a stable id, **never `$index`** for mutable lists (same
  reconciliation hazard as React keys / Vue `:key`). Use `@empty` for the no-rows branch.
- **`@defer` for below-the-fold / heavy subtrees** — lazy-load a block on `viewport`, `idle`,
  `interaction`, or `timer`, with `@placeholder` / `@loading` / `@error`. It's the first-class
  code-split lever; reach for it before manual dynamic imports.

```html
@defer (on viewport) {
  <app-analytics-chart [data]="rows()" />
} @placeholder { <app-chart-skeleton /> } @loading (after 100ms) { <app-spinner /> }
```

## 10. State management: signals first, SignalStore at scale

| Scope | Home |
|---|---|
| Local component state | `signal()` / `computed()` |
| Shared feature state | a `providedIn`-scoped service exposing `Signal`s (private writable, public read-only) |
| Server cache | `httpResource()` / `toSignal` over `HttpClient` — don't hand-copy into a store |
| Complex cross-cutting state _(scale-up)_ | **NgRx SignalStore** (`signalStore`, `withState`, `withComputed`, `withMethods`) |

- **Expose read-only signals**, keep the writable signal private — callers read, the owner writes.
  Don't hand a writable `signal` out of a service.
- **Reach for NgRx SignalStore, not the classic Redux/`@ngrx/store` boilerplate**, when state is
  genuinely app-wide with derived/async coordination. Most features never need a global store.

## 11. Accessibility (first-class)

Target **WCAG 2.2 AA** — full rules in [accessibility.md](../practices/accessibility.md). Angular
specifics:

- **Semantic HTML first**; use the CDK (`@angular/cdk/a11y`) `FocusTrap`, `LiveAnnouncer`, and
  `cdkTrapFocus` for dialogs/menus rather than re-rolling focus management.
- **Manage focus on navigation** — Angular doesn't move focus on route change; move it to the new
  view's heading so screen-reader and keyboard users aren't stranded.
- **Honour `prefers-reduced-motion`** before adding Angular animations; gate non-essential motion.

## 12. Build & tooling (Angular CLI + esbuild)

```bash
ng serve                      # dev server (Vite-backed, esbuild)
ng build                      # prod build via @angular/build:application (esbuild/esbuild)
ng test                       # unit tests
ng e2e                        # Playwright
```

- **`@angular/build:application` (esbuild) is the builder** — the legacy Webpack/`browser`
  builder is deprecated; migrate. SSR/hydration via `provideClientHydration()` when you need it.
- **Budgets fail the build, not review** — set `initial`/`anyComponentStyle` budgets in
  `angular.json` and ratchet them down; hold a Core Web Vitals budget (LCP ≤ 2.5s, INP ≤ 200ms,
  CLS ≤ 0.1) with Lighthouse-CI.
- **No secrets in `environment.ts`** — front-end config is shipped plaintext in the bundle; the
  secret boundary is owned by [security.md](../practices/security.md).

## 13. Testing (Testing Library + Playwright)

| Layer | Tool |
|---|---|
| Unit / component | **Jest or Vitest** + **@testing-library/angular** |
| Component harnesses | **Angular CDK Component Harnesses** for Material/CDK widgets |
| E2E | **Playwright** — see [testing-strategy.md](../practices/testing-strategy.md) |

- **Migrate off Karma/Protractor** — both are deprecated/removed. Jest or Vitest is the runner;
  mechanics (coverage ratchet, determinism) live in [typescript.md](../languages/typescript.md) §11.
- **Test behaviour, not internals** — query by role/label/text with Testing Library and drive
  `userEvent`; assert rendered output and accessibility, not signal internals or DI wiring.
- **Mock the network at the boundary** (`provideHttpClientTesting` or MSW), assert against the
  same Zod schemas the app parses with — never hand-mock `fetch`.

## Definition of done

- [ ] Language DoD met ([typescript.md](../languages/typescript.md) §10): `biome ci`/`tsc`, tests, supply chain
- [ ] Standalone only — no new `NgModule`; bootstrapped via `bootstrapApplication` (§1)
- [ ] Signal-based `input`/`output`/`model`/queries; effects do side effects only, never derive state (§2)
- [ ] `OnPush` on every component; zoneless on new apps; no manual `detectChanges()` (§3)
- [ ] `inject()` + `providedIn: 'root'`; functional guards/resolvers/interceptors (§4–§5, §8)
- [ ] Features lazy-loaded; routes typed; no eager feature imports at the root (§5)
- [ ] No bare `subscribe()` without `takeUntilDestroyed()`/`AsyncPipe`; signals for state, RxJS for streams (§6)
- [ ] Typed reactive forms (`nonNullable`); HTTP responses Zod-parsed at the boundary (§7–§8)
- [ ] Built-in `@if`/`@for`(with `track`, not `$index`)/`@switch`; `@defer` for heavy blocks (§9)
- [ ] esbuild `application` builder; bundle budgets + Web Vitals enforced; no secrets in `environment.ts` (§12)
- [ ] a11y gate passes (focus on nav, CDK a11y, WCAG 2.2 AA) (§11); behaviour tests green, no Karma/Protractor (§13)

**Sources:** [angular.dev — Signals](https://angular.dev/guide/signals) ·
[angular.dev — Zoneless](https://angular.dev/guide/zoneless) ·
[angular.dev — Components & standalone](https://angular.dev/guide/components/importing) ·
[angular.dev — `httpResource`](https://angular.dev/guide/http/http-resource) ·
[angular.dev — Control flow](https://angular.dev/guide/templates/control-flow) &
[`@defer`](https://angular.dev/guide/templates/defer) ·
[NgRx SignalStore](https://ngrx.io/guide/signals/signal-store) ·
[testing-library/angular](https://testing-library.com/docs/angular-testing-library/intro)
