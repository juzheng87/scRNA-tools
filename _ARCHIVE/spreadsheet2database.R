# This script was used to convert the scRNA-tools database from the old format
# (which was a single CSV file) to the new format which consists of multiple
# TSV files. It is included in this repository for reference purposes and in
# case there are any issues in the future.
#
# Luke Zappia
# 2019-09-17

library("dplyr")
library("tidyr")
library("readr")
library("stringr")
library("purrr")
library("tibble")
library("lubridate")
library("rcrossref")
library("aRxiv")

swsheet <- read_csv(
    "single_cell_software.csv",
    col_types = cols(
        .default    = col_logical(),
        Name        = col_character(),
        Platform    = col_character(),
        DOIs        = col_character(),
        PubDates    = col_character(),
        Code        = col_character(),
        Description = col_character(),
        License     = col_character(),
        Added       = col_date(format = ""),
        Updated     = col_date(format = "")
    )
)

tools <- swsheet %>%
    select(Tool = Name, Platform, Code, Description, License, Added, Updated)

cat_idx <- swsheet %>%
    gather(key = "Category", value = "Val",
           -Name, -Platform, -DOIs, -PubDates, -Code, -Description, -License,
           -Added, -Updated) %>%
    filter(Val == TRUE) %>%
    select(Tool = Name, Category)

dois <- swsheet %>%
    separate_rows(DOIs, sep = ";") %>%
    select(Tool = Name, DOI = DOIs) %>%
    drop_na(DOI)

papers <- dois %>%
    mutate(
        bioRxiv = str_detect(DOI, "^10.1101/"),
        arXiv   = str_detect(DOI, "arxiv"),
        PeerJ   = str_detect(DOI, "10.7287/")
    ) %>%
    mutate(
        Preprint = bioRxiv | arXiv | PeerJ
    ) %>%
    select(-Tool)

cr_dois <- papers %>%
    filter(!arXiv) %>%
    pull(DOI)

cr_refs <- map_dfr(cr_dois, function(x) {
    message(x)
    for (i in 1:10) {
        tryCatch({
            ref <- rcrossref::cr_works(x)
            break
        }, error = function(e) {
            message("Failed ", i)
        })
    }
    ref$data
})

cr_refs2 <- cr_refs %>%
    select(DOI = doi, Date = issued, Title = title)

arxiv_refs <- papers %>%
    filter(arXiv) %>%
    pull(DOI) %>%
    str_remove("arxiv/") %>%
    aRxiv::arxiv_search(id_list = .)

arxiv_refs2 <- arxiv_refs %>%
    select(DOI = id, Title = title) %>%
    mutate(
        DOI = paste0("arxiv/", str_remove(DOI, "v[0-9]+")),
        Date = NA
    )

refs <- bind_rows(cr_refs2, arxiv_refs2)

citations <- dois %>%
    distinct(DOI) %>%
    filter(!str_detect(DOI, "arxiv/")) %>%
    pull(DOI) %>%
    map_dfr(function(x) {
        message(x)
        for (i in 1:10) {
            tryCatch({
                cites <- rcrossref::cr_citation_count(x)
                break
            }, error = function(e) {
                message("Failed ", i)
            })
        }
        cites
    }) %>%
    rename(DOI = doi, Count = count) %>%
    mutate(Timestamp = lubridate::now("UTC")) %>%
    mutate(Delay = 0)

references <- papers %>%
    left_join(refs, by = "DOI") %>%
    left_join(citations, by = "DOI") %>%
    select(DOI, arXiv, Preprint, Date, Title, Citations = Count,
           Timestamp, Delay) %>%
    mutate(Title = str_squish(Title)) %>%
    distinct()

bioc_url <- "https://bioconductor.org/packages/release/bioc/"
bioc_pkgs <- xml2::read_html(bioc_url) %>%
    rvest::html_nodes("table") %>%
    rvest::html_nodes("a") %>%
    rvest::html_text()
names(bioc_pkgs) <- str_to_lower(bioc_pkgs)

cran_url <- "https://cran.r-project.org/web/packages/available_packages_by_name.html"
cran_pkgs <- xml2::read_html(cran_url) %>%
    rvest::html_nodes("a") %>%
    rvest::html_text() %>%
    setdiff(LETTERS) # Remove letter links at top of page

pypi_pkgs <- xml2::read_html("https://pypi.python.org/simple/") %>%
    rvest::html_nodes("a") %>%
    rvest::html_text()

conda_pages <- xml2::read_html("https://anaconda.org/anaconda/repo") %>%
    rvest::html_nodes(".unavailable:nth-child(2)") %>%
    rvest::html_text() %>%
    stringr::str_split(" ") %>%
    unlist()
conda_pages <- as.numeric(conda_pages[4])

conda_pkgs <- pbapply::pbsapply(seq_len(conda_pages), function(page) {
    url <- paste0(
        "https://anaconda.org/anaconda/repo?sort=_name&sort_order=asc&page=",
        page
    )

    xml2::read_html(url) %>%
        rvest::html_nodes(".packageName") %>%
        rvest::html_text()
})
conda_pkgs <- unlist(conda_pkgs)

pkgs_cache <- tibble(
    Name = c(bioc_pkgs, cran_pkgs, pypi_pkgs, conda_pkgs),
    Type = c(
        rep("Bioc",  length(bioc_pkgs)),
        rep("CRAN",  length(cran_pkgs)),
        rep("PyPI",  length(pypi_pkgs)),
        rep("Conda", length(conda_pkgs))
    ),
    Added = lubridate::now("UTC")
) %>%
    mutate(Repository = paste(Name, Type, sep = "@")) %>%
    select(Repository, Name, Type, Added)

repos_list <- jsonlite::fromJSON("docs/data/repositories.json")

repos <- names(repos_list) %>%
    map_dfr(function(tool) {
        bioc  <- repos_list[[tool]]$BioC
        cran  <- repos_list[[tool]]$CRAN
        pypi  <- repos_list[[tool]]$PyPI
        conda <- repos_list[[tool]]$Conda
        tibble(
            Tool  = tool,
            Bioc  = if_else(is_null(bioc),  NA_character_,  bioc),
            CRAN  = if_else(is_null(cran),  NA_character_,  cran),
            PyPI  = if_else(is_null(pypi),  NA_character_,  pypi),
            Conda = if_else(is_null(conda), NA_character_, conda),
        )
    })

ignored <- names(repos_list) %>%
    map_dfr(function(tool) {

        ignore <- repos_list[[tool]]$Ignored

        if (is.null(ignore)) {
            return(NULL)
        }

        ignore_df <- str_split(ignore, "/", simplify = TRUE)

        tibble(
            Tool   = tool,
            Type   = ignore_df[, 1],
            Name   = ignore_df[, 2],
        )
    }) %>%
    mutate(Type = if_else(Type == "BioC", "Bioc", Type)) %>%
    arrange(Tool, Type, Name)

github <- tools %>%
    filter(str_detect(Code, "github.com")) %>%
    mutate(
        GitHub = str_remove(Code, "https://github.com/")
    ) %>%
    select(Tool, GitHub)

repositories <- repos %>%
    full_join(github, by = "Tool")

categories <- jsonlite::read_json("docs/data/descriptions.json",
                                  simplifyVector = TRUE)

write_tsv(tools,        "database/tools.tsv")
write_tsv(references,   "database/references.tsv")
write_tsv(dois,         "database/doi-idx.tsv")
write_tsv(cat_idx,      "database/categories-idx.tsv")
write_tsv(repositories, "database/repositories.tsv")
write_tsv(ignored,      "database/ignored.tsv")
write_tsv(pkgs_cache,   "database/packages-cache.tsv")
write_tsv(categories,   "database/categories.tsv")
