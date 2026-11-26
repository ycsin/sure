// Layout helpers for the cash flow Sankey charts: the label side, and the
// node order for a second layout pass (below). (Column assignment is
// d3-sankey's sankeyCenter: a sink at its depth, a source one column before
// the nearest node it feeds, so a category without subcategories stays in
// the category column and the surplus and invested outflows end beside Cash
// Flow instead of flush right across the categories.)
//
// Labels face the middle of the chart so neither edge cuts them off. The
// surplus and invested outflows are the exception: beside Cash Flow, a
// label facing the middle shares the gap with the Cash Flow label and
// loses to it under the overlap rule, so theirs goes on the right, where
// nothing flows out of them, unless that is the chart's edge.
const OUTFLOW_IDS = new Set(["surplus_node", "invested_node"]);

export function sankeyLabelOnRight(nodes, width) {
  const lastColumn = Math.max(...nodes.map((node) => node.layer));
  return (node) =>
    (OUTFLOW_IDS.has(node.id) && node.layer < lastColumn) ||
    node.x0 < width / 2;
}

const CASH_FLOW_ID = "cash_flow_node";

// A node order for a second layout pass (d3-sankey's nodeSort). d3-sankey
// orders each column by nudging nodes towards the links that feed them,
// which can leave a large subcategory above the subcategory of a parent
// placed higher, so their links cross. This keeps every column in the order
// the first pass left it, except that a subcategory goes where its parent
// went: a column of subcategories then follows the order of their parents,
// and no two category-to-subcategory links cross.
//
// Node ids carry the hierarchy (see sankey_subcategories.mjs): a subcategory
// is "<side>_sub_<category id>", linked to its parent only, or straight to
// Cash Flow when its net direction runs against its parent. Returns null
// when no subcategory has a parent, as the first pass then stands.
export function sankeyParentOrder(graph) {
  const position = new Map(graph.nodes.map((node) => [node.id, node.y0]));
  const parentIds = new Map();
  for (const node of graph.nodes) {
    if (!String(node.id).includes("_sub_")) continue;

    const links = [...node.sourceLinks, ...node.targetLinks];
    if (links.length !== 1) continue;

    const other = links[0].source === node ? links[0].target : links[0].source;
    if (other.id !== CASH_FLOW_ID) parentIds.set(node.id, other.id);
  }
  if (!parentIds.size) return null;

  const rank = (node) => [
    position.get(parentIds.get(node.id) ?? node.id),
    position.get(node.id),
  ];
  return (a, b) => {
    const [aParent, aOwn] = rank(a);
    const [bParent, bOwn] = rank(b);
    return aParent - bParent || aOwn - bOwn;
  };
}
