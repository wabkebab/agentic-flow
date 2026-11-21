# Only the first line may carry a transition or hold marker. Strip one exact
# opener and leave the marker text intact for the caller's validation.
def journal_marker_line: (split("\n")[0] // "") | ltrimstr("<!-- ");
