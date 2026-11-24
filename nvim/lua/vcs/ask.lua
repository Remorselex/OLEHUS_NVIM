-- Confirmation of a destructive action: a two-item picker (snacks) instead of confirm(),
-- whose hotkeys come from the labels and clash when two labels start with the same letter.
return function(question, action_label, on_confirmed, on_cancelled)
  vim.ui.select({ action_label, "Cancel" }, { prompt = question }, function(choice)
    if choice == action_label then
      on_confirmed()
    elseif on_cancelled then
      on_cancelled()
    end
  end)
end
