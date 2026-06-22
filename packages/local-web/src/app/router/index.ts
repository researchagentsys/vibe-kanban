import { createRouter } from '@tanstack/react-router';
import { routeTree } from '@web/routeTree.gen';

// basepath = the deploy prefix so client-side navigation/hrefs keep it. '/' by
// default; under the sandbox path-prefix it's import.meta.env.BASE_URL, baked as
// the /__VKBASE__/ placeholder and server-replaced to /cs/<id>/ at serve time.
export const router = createRouter({
  routeTree,
  basepath: import.meta.env.BASE_URL,
});

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
