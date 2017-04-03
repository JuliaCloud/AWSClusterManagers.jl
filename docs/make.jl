using Documenter, AWSClusterManagers

makedocs(
    modules = [AWSClusterManagers],
    format = :html,
    pages = [
        "Home" => "index.md",
        "Design" => "pages/design.md",
    ],
    repo = "https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/blob/{commit}{path}#L{line}",
    sitename = "AWSClusterManagers.jl",
    authors = "Curtis Vogt",
    assets = ["assets/invenia.css"],
)
