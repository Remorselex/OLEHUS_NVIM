-- Markdown right in the buffer: headings, tables, code blocks and checkboxes are rendered, while the line
-- under the cursor stays raw so it can be edited. Space u m toggles it on/off.
-- Heading levels differ by numbered icons, not just by background colour.
return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    opts = {
      code = { sign = false, width = "block", right_pad = 1 },
      heading = { sign = false },
    },
    config = function(_, opts)
      require("render-markdown").setup(opts)
      Snacks.toggle({
        name = "Markdown as a page",
        get = require("render-markdown").get,
        set = require("render-markdown").set,
      }):map("<leader>um")
    end,
  },
}
