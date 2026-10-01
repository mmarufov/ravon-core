// The Admin GraphQL operations the worker sends. Named, so the harness's fake Shopify can
// route on operationName and so throttle events say which call was paced.

export const SWEEP_ORDERS = /* GraphQL */ `
  query RavonSweepOrders($q: String!, $after: String, $first: Int!) {
    orders(first: $first, after: $after, sortKey: UPDATED_AT, query: $q) {
      pageInfo { hasNextPage endCursor }
      nodes { id name createdAt updatedAt cancelledAt cancelReason }
    }
  }
`;

export const ORDER_FULFILLMENT_STATE = /* GraphQL */ `
  query RavonOrderFulfillmentState($id: ID!) {
    order(id: $id) {
      id
      cancelledAt
      displayFulfillmentStatus
      fulfillments(first: 20) {
        id
        status
        createdAt
        trackingInfo(first: 5) { number company }
      }
      fulfillmentOrders(first: 10) {
        nodes {
          id
          status
          lineItems(first: 50) { nodes { id remainingQuantity } }
        }
      }
    }
  }
`;

export const FULFILLMENT_CREATE = /* GraphQL */ `
  mutation RavonFulfillmentCreate($fulfillment: FulfillmentInput!) {
    fulfillmentCreate(fulfillment: $fulfillment) {
      fulfillment { id status trackingInfo(first: 5) { number } }
      userErrors { field message }
    }
  }
`;
