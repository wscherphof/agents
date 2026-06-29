---
description: >-
  Use when working in the legacy AngularJS app under app/. Covers
  window.app registration, Vite template URL imports, modelService event
  patterns, and legacy naming conventions.
name: "Legacy AngularJS"
applyTo: "app/**/*.js, app/**/*.html, app/**/*.scss"
---

# Legacy AngularJS App

- This code lives in `app/` and is the production AngularJS 1.8.3 application.
- Never create new AngularJS modules. Register services, controllers, and
	other AngularJS artifacts on the existing global `window.app` module.
- Follow the existing AngularJS naming patterns such as `serviceName.js`,
	`ctrlName.js`, and `gridName.js`.
- Template imports in the Vite-based AngularJS app require the `?url` suffix.

```javascript
import src from './template.html?url';
$scope.src = $sce.trustAsResourceUrl(src);
```

- State updates commonly flow through the event system in
	`app/src/modelService.js`.

```javascript
modelService.update('model-grid', 'ONDERZOEKEN', element);
$rootScope.$on('model-grid', (_, model) => { /* handle */ });
```

- Utility validators and custom comparers used across the legacy app live in
	`app/src/utils.js`.
