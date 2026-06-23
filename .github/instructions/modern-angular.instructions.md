---
description: >-
  Use when working in the modern Angular app under docker/ng. Covers
  standalone components, inject(), signals, Angular naming conventions,
  grid initialization patterns, and when to use the Angular Advisor agent.
name: "Modern Angular"
applyTo: "docker/ng/**/*.ts, docker/ng/**/*.html, docker/ng/**/*.scss"
---

# Modern Angular App

- This code lives in `docker/ng/` and is the migration target built with
  modern Angular standalone components, signals, and TypeScript.
- Prefer standalone components with `inject()` over constructor injection when
  following existing project patterns.

```typescript
@Component({
  selector: 'app-component',
  imports: [MatTabsModule],
})
export class Component {
  protected readonly service = inject(StateService);
  protected readonly value = this.service.signal;
}
```

- Use `@Service()` (imported from `@angular/core`) instead of
  `@Injectable({ providedIn: 'root' })` for global singleton services.
  Fall back to `@Injectable` only when deeper configuration or constructor
  injection is required.

```typescript
import { Service } from '@angular/core';

@Service()
export class DataService {
  private readonly _items = signal<Item[]>([]);
  readonly items = this._items.asReadonly();
}
```

- `OnPush` is the default change detection strategy in Angular 22. Do not set
  `changeDetection` in `@Component` — omitting it is correct.

- Services commonly expose signal-based state via a private writable signal
  and a public readonly signal.

```typescript
private readonly _selectedTab = signal<Tab>(Tab.Project);
public readonly selectedTab = this._selectedTab.asReadonly();
```

- Follow Angular naming conventions such as `name.component.ts` and
  `name.service.ts`.
- In `docker/ng/`, Angular Material (AM) is the default UI framework.
  Prefer existing AM-based patterns for dialogs, form fields, buttons, tabs,
  and table/grid-adjacent controls before introducing custom UI primitives.
- Modern grid services avoid circular dependencies via the
  `initializeGrid()` pattern.
- When Angular Material API behavior or component usage is unclear, verify
  against official Angular documentation via the Angular MCP documentation
  search tool before implementing changes.
- For Angular architecture questions, API usage, best-practice checks, or
  Angular-focused code changes, prefer the `Angular Advisor` agent.
