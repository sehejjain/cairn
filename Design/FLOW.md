# Flow

Flow organizes Cairn around four tasks: checking today, reviewing activity,
planning expenses, and understanding wealth. Financial figures and aligned rows
provide the hierarchy. Spacing and thin rules group content without enclosing
every section in a card.

## Appearance

- Use the adaptive `CairnCanvas`, `CairnSurface`, and `CairnSurfaceInset` assets.
  The light canvas is warm gray; dark appearance uses charcoal surfaces.
- Cobalt identifies actions, progress, and primary chart lines. Reserve green
  and red for financial changes. Preserve the person's expense category colors.
- Use system text styles and Dynamic Type. Large balances use rounded medium
  numerals; supporting amounts use tabular figures.
- Keep content within a 760-point reading width. Let labels, controls, and amounts
  stack when larger text needs more room. Preserve 44-point control targets.
- On Mac, dashboards use up to 1,440 points across the window. Related summaries
  sit in columns and stack when there is insufficient room for usable charts
  and rows. Keep forms and prose at their narrower reading width.
- Use native navigation, menus, sheets, and toolbars. Liquid Glass belongs to
  controls and navigation; charts remain on opaque content surfaces.

## Navigation

Today shows monthly spending, budget progress, net worth, and upcoming payments.
Activity supports transaction review and search. Plan contains category limits,
recurring payments, funds, and shared expenses. Wealth brings the balance sheet
and investment details together. Settings remains reachable from a toolbar even
when its optional navigation destination is hidden. Saved navigation preferences
remain usable.

Mac uses a compact destination picker in the window toolbar. It leaves the
content width available for charts, accounts, and planning. Changing destination
returns to that destination's overview; Settings uses the native settings window.

Plan leads with the month’s category-limit progress and a compact category
shortlist ordered by overruns and spending. The full limits list remains one
step away. Upcoming payments, fund progress, shared expenses, and the cash-flow
forecast sit alongside the budget on wide windows and follow it on phones.

## Charts

- Use solid cobalt lines, restrained currency axes, and thin grid lines.
  Connect observed daily values linearly. Use a zero baseline for spending.
- Scrubbing changes the large amount and date above the chart. The chart's
  selection rule and dot identify the same point. Avoid a second readout below.
- Preserve the selected value after lifting a finger. Keep readout height stable
  and preserve the chart during background refreshes in the same currency and month.
- Actual spending uses the Spending calculator. Budget smoothing affects the
  plan ruler, without changing the actual-spending line. A fetch error shows an
  unavailable state instead of a partial total.
- Actual spending and projections use distinct solid and dashed lines.
- Expense donuts show positive spending only. Aggregate small slices when there
  are more than six categories, while retaining all categories in the list.
  Keep amounts and names available without relying on color.
- Preserve currency boundaries. Explain transaction-derived balance history
  separately from investment performance. Planned payments and fund allocations
  do not become posted spending or available cash.
- Retain chart accessibility, selection feedback, reduced-motion behavior, and
  useful empty states. Validate the rendered app in both appearances and with
  accessibility text sizes.

## References

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Apple design resources](https://developer.apple.com/design/resources/)
- [Swift Charts](https://developer.apple.com/documentation/charts)
