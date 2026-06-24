---
description: >
  Use when working on SlickGrid grids in docker/ng. Covers the Angular-Slickgrid
  bootstrap pattern, selection model, locale requirements, grid architecture,
  regression-sensitive behaviors, and upgrade guidance.
applyTo: "src/app/tabs/**/*.ts, src/app/app.config.ts, src/app/common/locales/**"
---

# SlickGrid integration (GeoWEP ng)

## Current versions
- `angular-slickgrid`: `^10.5.1`
- `@slickgrid-universal/composite-editor-component`: `^10.5.1`
- `@slickgrid-universal/custom-tooltip-plugin`: `^10.5.1`

## Architecture
- Core shared grid abstraction: `src/app/tabs/common/grid/grid.service.ts`.
- Grid architecture pattern: feature services expose `initializeGrid(grid:
  GridService<T>)` to the host component to avoid circular dependencies.
- Angular-Slickgrid app bootstrapping: `src/app/app.config.ts`.
- Grid-hosting tab components import `AngularSlickgridComponent` (standalone)
  directly:
  - `src/app/tabs/onderzoeken/`
  - `src/app/tabs/metadata/`
  - `src/app/tabs/project/{klic,aantekeningen,notities,plantekeningen,projectkaarten}/`

## Bootstrap pattern (app.config.ts)
No `AngularSlickgridModule.forRoot()` from v10 onwards. Use:

```typescript
import { AngularSlickgridComponent, GridOption } from 'angular-slickgrid';
const defaultGridOption: GridOption = { locales: localeDutch };
// in providers array:
AngularSlickgridComponent,
{ provide: 'defaultGridOption', useValue: defaultGridOption },
importProvidersFrom(TranslateModule.forRoot({})),
```

`TranslateModule.forRoot({})` is still required in v10 to support deferred
component injector contexts.

## Selection model
- Use `SlickHybridSelectionModel` (import from `'angular-slickgrid'`).
  `SlickCellSelectionModel` was removed in v10.
- `SlickHybridSelectionModel` accepts `{ selectActiveCell, cellRangeSelector }`
  — direct drop-in for the old `SlickCellSelectionModel`.
- `SlickCellRangeSelector` is still available in v10 and still used in
  `grid.service.ts`.
- The `cellSelectionModel` property name on `GridService` was NOT changed; all
  callsites remain valid.

## Locale
- Dutch locale object: `src/app/common/locales/nl.ts`.
- The `Locale` interface requires `TEXT_EXPORT_TO_PDF: string` (added in v10).
  Dutch value: `'Exporteren naar PDF'`.

## Selection-related callsites — re-check on every SlickGrid upgrade
- `src/app/tabs/common/grid/grid.service.ts`
- `src/app/tabs/common/grid/selection/selection.component.ts`
- `src/app/tabs/onderzoeken/toolbar/toolbar.component.ts`
- `src/app/tabs/metadata/toolbar/toolbar.component.ts`
- `src/app/tabs/onderzoeken/editor-onderzoeken-grid.service.ts`

## Regression-sensitive behaviors
- Pointer-type handling (`mouse`/`touch`/`pen`) in shared grid service drives
  selection/edit UX — do not alter without manual device testing.
- `cellRangeSelector.onCellRangeSelecting` subscription (touch long-press).
- `cellSelectionModel.onSelectedRangesChanged` subscription (mouse selection).
- Critical manual regression flows after any SlickGrid change:
  - **Onderzoeken**: range selection → context-menu edit → selection restore
    after edit/cancel.
  - **KLIC**: `onBeforeEditCell` and `onCellChange` editing interactions with
    selection active.
  - **Metadata / Onderzoeken toolbars**: clear selection + export actions.

## Grid options in use
`enableCellNavigation`, `enableExcelCopyBuffer`, filtering, grouping,
`SlickCustomTooltip` external plugin resource.

## Validation commands
```bash
npm run lint
npx tsc --noEmit   # fast type-check without emit
npm run build
```

## Upstream references
- Slickgrid-Universal releases:
  `https://github.com/ghiscoding/slickgrid-universal/releases`
- Angular-Slickgrid migration guide v10:
  `https://ghiscoding.gitbook.io/angular-slickgrid/migrations/migration-to-10.x`
- Angular-Slickgrid quick start:
  `https://ghiscoding.gitbook.io/angular-slickgrid/getting-started/quick-start`
