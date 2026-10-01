// How the worker reaches the Admin GraphQL API.
//
// `templateAdmin` is the template's client (`unauthenticated.admin`, which loads the
// offline session and refreshes its token). It is not this project's code. `fetchAdmin`
// is a plain fetch used only against the harness's fake Shopify. Both return the raw
// GraphQL body, errors and extensions included, and never throw on a GraphQL error, so
// throttle.server.ts can read `extensions.cost` on every response, throttled or not.

export interface GraphqlResult {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  data?: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  errors?: any[];
  extensions?: {
    cost?: {
      requestedQueryCost?: number;
      actualQueryCost?: number | null;
      throttleStatus?: {
        maximumAvailable: number;
        currentlyAvailable: number;
        restoreRate: number;
      };
    };
  };
}

export interface AdminGraphql {
  request(query: string, variables?: Record<string, unknown>): Promise<GraphqlResult>;
}

export function fetchAdmin(baseUrl: string, shop: string, token: string, apiVersion: string): AdminGraphql {
  const url = `${baseUrl.replace(/\/$/, "")}/admin/api/${apiVersion}/graphql.json`;
  return {
    async request(query, variables) {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-shopify-access-token": token,
          "x-shopify-shop-domain": shop,
        },
        body: JSON.stringify({ query, variables }),
      });
      const body = (await res.json()) as GraphqlResult;
      if (!res.ok && !body.errors) throw new Error(`admin api HTTP ${res.status}`);
      return body;
    },
  };
}

export async function templateAdmin(shop: string): Promise<AdminGraphql> {
  const { unauthenticated } = await import("../shopify.server");
  return {
    async request(query, variables) {
      const { admin } = await unauthenticated.admin(shop);
      try {
        const res = await admin.graphql(query, { variables });
        return (await res.json()) as GraphqlResult;
      } catch (e) {
        // The template client throws GraphqlQueryError on any GraphQL error, THROTTLED
        // included, with the full body attached.
        const body = (e as { body?: GraphqlResult }).body;
        if (body && (body.errors || body.extensions)) {
          return {
            data: body.data,
            errors: Array.isArray(body.errors)
              ? body.errors
              : // eslint-disable-next-line @typescript-eslint/no-explicit-any
                ((body.errors as any)?.graphQLErrors ?? [body.errors]),
            extensions: body.extensions,
          };
        }
        throw e;
      }
    },
  };
}
