import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { sankeyLabelOnRight, sankeyParentOrder } from "../../app/javascript/utils/sankey_align.mjs"

describe("sankeyLabelOnRight", () => {
  const WIDTH = 1000
  const nodes = [
    { id: "income_work", layer: 1, x0: 200 },
    { id: "cash_flow_node", layer: 2, x0: 492 },
    { id: "expense_food", layer: 3, x0: 744 },
    { id: "surplus_node", layer: 3, x0: 744 },
    { id: "expense_sub_uk_tax", layer: 4, x0: 969 },
  ]
  const onRight = sankeyLabelOnRight(nodes, WIDTH)

  it("faces labels towards the middle of the chart", () => {
    assert.equal(onRight(nodes[0]), true)
    assert.equal(onRight(nodes[1]), true)
    assert.equal(onRight(nodes[2]), false)
    assert.equal(onRight(nodes[4]), false)
  })

  it("puts the surplus label on its right, away from the Cash Flow label", () => {
    assert.equal(onRight(nodes[3]), true)
  })

  it("keeps a surplus in the last column facing the middle", () => {
    const threeColumns = [
      { id: "cash_flow_node", layer: 1, x0: 492 },
      { id: "surplus_node", layer: 2, x0: 969 },
    ]
    assert.equal(sankeyLabelOnRight(threeColumns, WIDTH)(threeColumns[1]), false)
  })
})

// A laid-out graph as d3-sankey leaves it: nodes with their first-pass
// position (y0) and links pointing at the node objects.
function graph(positions, links) {
  const nodes = Object.entries(positions).map(([id, y0]) => ({ id, y0, sourceLinks: [], targetLinks: [] }))
  const byId = Object.fromEntries(nodes.map((node) => [node.id, node]))
  for (const [source, target] of links) {
    const link = { source: byId[source], target: byId[target] }
    byId[source].sourceLinks.push(link)
    byId[target].targetLinks.push(link)
  }
  return { nodes, byId }
}

const sorted = (order, nodes) => [...nodes].sort(order).map((node) => node.id)

describe("sankeyParentOrder", () => {
  it("leaves the first pass standing without a subcategory under a parent", () => {
    const { nodes } = graph(
      { income_salary: 10, cash_flow_node: 10, expense_food: 5, expense_sub_refund: 80 },
      [
        ["income_salary", "cash_flow_node"],
        ["cash_flow_node", "expense_food"],
        // A subcategory whose net runs against its parent is linked to Cash Flow.
        ["expense_sub_refund", "cash_flow_node"],
      ],
    )
    assert.equal(sankeyParentOrder({ nodes }), null)
  })

  it("places subcategories in their parents' order, then in their own", () => {
    const { nodes, byId } = graph(
      {
        cash_flow_node: 10,
        expense_travel: 100,
        expense_housing: 160,
        expense_sub_flight: 90,
        expense_sub_attractions: 250,
        expense_sub_rent: 170,
      },
      [
        ["cash_flow_node", "expense_travel"],
        ["cash_flow_node", "expense_housing"],
        ["expense_travel", "expense_sub_flight"],
        ["expense_travel", "expense_sub_attractions"],
        ["expense_housing", "expense_sub_rent"],
      ],
    )
    const order = sankeyParentOrder({ nodes })
    const subcategories = ["expense_sub_rent", "expense_sub_attractions", "expense_sub_flight"].map((id) => byId[id])

    // The first pass left Rent above Attractions although Travel is above Housing.
    assert.deepEqual(sorted(order, subcategories), ["expense_sub_flight", "expense_sub_attractions", "expense_sub_rent"])
  })

  it("keeps the first pass's order for nodes without a parent", () => {
    const { nodes, byId } = graph(
      {
        cash_flow_node: 10,
        expense_travel: 100,
        expense_housing: 160,
        surplus_node: 40,
        expense_sub_rent: 170,
      },
      [
        ["cash_flow_node", "expense_travel"],
        ["cash_flow_node", "expense_housing"],
        ["cash_flow_node", "surplus_node"],
        ["expense_housing", "expense_sub_rent"],
      ],
    )
    const order = sankeyParentOrder({ nodes })
    const column = ["expense_housing", "surplus_node", "expense_travel"].map((id) => byId[id])

    assert.deepEqual(sorted(order, column), ["surplus_node", "expense_travel", "expense_housing"])
  })

  it("follows income categories for the income subcategories feeding them", () => {
    const { nodes, byId } = graph(
      {
        income_work: 50,
        income_investments: 20,
        cash_flow_node: 10,
        income_sub_salary: 15,
        income_sub_dividends: 60,
      },
      [
        ["income_work", "cash_flow_node"],
        ["income_investments", "cash_flow_node"],
        ["income_sub_salary", "income_work"],
        ["income_sub_dividends", "income_investments"],
      ],
    )
    const order = sankeyParentOrder({ nodes })
    const column = ["income_sub_salary", "income_sub_dividends"].map((id) => byId[id])

    assert.deepEqual(sorted(order, column), ["income_sub_dividends", "income_sub_salary"])
  })
})
