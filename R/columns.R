#' Selects columns or rows from the data set
#'
#' - `columns`: select columns from dataset. There are four ways of column selection:
#' 1. Simply by column names
#' 2. By variable ranges, e. g. vs:carb. Alternatively, you can use '%to%'
#' instead of colon: 'vs %to% carb'.
#' 3. With regular expressions. Characters which start with '^' or end with '$'
#' considered as Perl-style regular expression patterns. For example, '^Petal'
#' returns all variables started with 'Petal'. 'Width$' returns all variables
#' which end with 'Width'. Pattern '^.' matches all variables and pattern
#' '^.*my_str' is equivalent to contains "my_str"'.
#' 4. By character variables with interpolated parts. Expression in the curly
#' brackets inside characters will be evaluated in the parent frame with
#' [text_expand]. For example, `a{1:3}` will be transformed to the names 'a1',
#' 'a2', 'a3'. 'cols' is just a shortcut for 'columns'. See examples.
#' ```
#' ```
#' - `rows`: select rows from dataset by logical conditions.
#'
#'
#' @param data data.table/data.frame
#' @param ... unquoted or quoted column names, regex selectors or variable
#'   ranges for 'columns' and logical conditions for 'rows'.
#'
#' @return data.frame/data.table
#' @export
#' @examples
#'
#' ## columns
#' mtcars %>%
#'     columns(vs:carb, cyl)
#' mtcars %>%
#'     columns(-am, -cyl)
#'
#' # regular expression pattern
#' columns(iris, "^Petal") %>% head() # variables which start from 'Petal'
#' columns(iris, "Width$") %>% head() # variables which end with 'Width'
#' # move Species variable to the front.
#' # pattern "^." matches all variables
#' columns(iris, Species, "^.") %>% head()
#' # pattern "^.*i" means "contains 'i'"
#' columns(iris, "^.*i") %>% head()
#' # numeric indexing - all variables except Species
#' columns(iris, 1:4) %>% head()
#'
#' # variable expansion
#' dims = c("Width", "Length")
#' columns(iris, "Petal.{dims}") %>% head()
#'
#' # rows
#'
#' mtcars %>%
#'     rows(am==0) %>%
#'     head()
#'
#' # select rows with compound condition
#' mtcars %>%
#'     rows(am==0 & mpg>mean(mpg))
#'
columns = function(data, ...){
    UseMethod("columns")
}


#' @export
columns.data.frame = function(data, ...){
    # if data is expression we want to calculate it only once
    data = force(data)
    data_names = colnames(data)
    parent_frame = parent.frame()
    var_indexes = select_columns(...,
                                 data_names = data_names,
                                 frame = parent_frame,
                                 type = "index"
                                 )

    if(is.data.table(data)){
        data[, var_indexes, with = FALSE]
    } else {
        data[, var_indexes, drop = FALSE]
    }

}

#' @rdname columns
#' @export
cols = columns


is_columns = function(expr){
    is.call(expr) && (identical(expr[[1]], quote(columns)) || identical(expr[[1]], quote(cols)) || identical(expr[[1]], quote(`%to%`)))
}

# here we find `columns` expression and replace it with data.table(...) or c(...)
replace_column_expr = function(expr, data_names, frame,
                               type = c("data.table", "index", "names"),
                               new = FALSE){
    if(missing(expr)) return(missing_arg())
    type = match.arg(type)
    if(is.call(expr)){
        if(new){
            curr_action = quote(create_columns)
        } else {
            curr_action = quote(select_columns)
        }
        if(is_columns(expr)){
            if(identical(expr[[1]], quote(`%to%`))){
                expr = as.call(list(curr_action, expr)) # standalone a %to% b, without 'columns'
            } else {
                # 'columns(...)'
                expr[[1]] = curr_action
            }
            expr = as.call(c(as.list(expr),
                             list(data_names = data_names,
                                  frame = frame,
                                  type = type)
                             )
                           )
            expr = eval(expr)

        } else {
            res = lapply(as.list(expr),
                         replace_column_expr,
                         data_names = data_names,
                         frame = frame,
                         type = type,
                         new = new
                         )
            expr = as.call(res)
        }
    }
    expr
}


select_columns = function(..., data_names, frame, type){
    var_list = substitute(list(...))
    curr_range_expander = create_range_expander(data_names, frame)
    var_list = substitute_symbols(var_list, list(
        ":" = curr_range_expander,
        "%to%" = curr_range_expander,
        "-" = create_unary_minus(data_names, frame)
    ))
    all_indexes = create_list_with_index(data_names)
    var_list = eval(var_list, all_indexes, frame)
    # here we processed values which didn't resolved to numeric column index
    var_indexes = expand_characters(var_list, data_names, frame)
    var_indexes = unique(unlist(var_indexes, recursive = TRUE, use.names = FALSE))
    switch(type,
           "data.table"  = {
               all_symbols = create_list_with_symbols(data_names)
               res = all_symbols[var_indexes]
               as.call(c(quote(data.table), res))
           },
           "index" = var_indexes,
           "names" = data_names[var_indexes]

    )
}

create_columns = function(..., data_names, frame, type){
    var_list = substitute(list(...))
    var_list = eval_expressions(var_list, frame)
    # unknown names
    # it is for unquoted names
    new_names = setdiff(all.vars(var_list), data_names)

    curr_range_expander = create_range_expander(data_names, frame, new = TRUE)
    var_list = substitute_symbols(var_list, list(
        ":" = curr_range_expander,
        "%to%" = curr_range_expander
    ))
    all_names = create_list_with_names(c(data_names, new_names))
    var_list = eval(var_list, all_names, frame)
    new_names = expand_characters(var_list, data_names, frame, new = TRUE)
    unique(unlist(new_names, recursive = TRUE, use.names = FALSE))
}

eval_expressions = function(var_list, frame){
    # eval expressions, symbols remain as is
    if(length(var_list)>1){
        var_list = as.list(var_list)
        var_list[-1] = lapply(var_list[-1], function(item){
            if(is.call(item) && !(identical(item[[1]], quote(`:`)) || identical(item[[1]], quote(`%to%`)))){
                item = eval(item, envir = frame)
            }
            item
        })
        var_list = as.call(var_list)
    }
    var_list
}

###
expand_characters = function(selected, data_names, frame, new = FALSE){
    # expand text and regex
    selected = lapply(selected, function(item){
        # browser()
        if(is.character(item)){
            item = s_regex_expand(item, data_names)
            item = s_text_expand(item, data_names, frame)
            if(!new){
                item = create_index_vec(item, df_names = data_names)
            }
        }
        item

    })
    selected
}

create_unary_minus = function(data_names, frame){
    force(data_names)
    force(frame)
    function(e1, e2){
        if(missing(e2)){
            if(is.character(e1)){
                var_indexes = expand_characters(e1, data_names, frame)
                var_indexes = unique(unlist(var_indexes, recursive = TRUE, use.names = FALSE))
                return(-var_indexes)
            } else {
                return(-e1)
            }
        }
        base::`-`(e1, e2)
    }
}

is_regex = function(txt){
    is.character(txt) && any(startsWith(txt, "^") | endsWith(txt, "$"))
}

s_regex_expand = function(expr, df_names){
    # TODO here we have possible unexpected behaviour - when expr is vec of several character
    # if one of them is regex all other will be considered as regex
    if(!is_regex(expr)) return(expr)
    res = lapply(expr, grep, x = df_names, perl = TRUE, value = TRUE)
    res = unlist(res, recursive = TRUE, use.names = FALSE)
    (length(res)==0) && stop(paste("'columns' - there are no variables which match regex(-s): ", paste(expr, collapse = ",")))
    unlist(res, recursive = TRUE, use.names = TRUE)
}

s_text_expand = function(expr, df_names, frame){
    res = eval(substitute(maditr::text_expand(item), list(item = expr)), envir = frame)
    unlist(res, recursive = TRUE, use.names = TRUE)
}

create_range_expander = function(df_names, frame, new = FALSE){
    force(df_names)
    function(from, to){   # , frame, new = FALSE
        from = substitute(from)
        to = substitute(to)
        if(is.call(from)) from = eval(from, frame)
        if(is.call(to)) to = eval(to, frame)
        if(is.symbol(from)) from = as.character(from)
        if(is.symbol(to)) to = as.character(to)
        if(is.numeric(from) && is.numeric(to)) { #
            if(new){
                res = df_names[from:to]
                !anyNA(res) || stop("'columns' range selection: positions ", from, ":", to, " out of range.")
                return(res)
            } else {
                return(from:to)
            }
        }
        first = match(from, df_names)[1]
        last = match(to, df_names)[1]
        if(is.na(first) && is.na(last) && new) return(
            create_name_sequence(from, to)
        )
        (!is.na(first) &&  !is.na(last)) || stop("'columns' range selection: variables '", from, "' or '", to, "' are not found.")
        (last>=first) || stop( "'columns' range selection: '",to, "' located before '",from,"'. Did you mean '",to," %to% ",from,"'?")
        if(new) df_names[first:last] else first:last
    }
}

create_index_vec = function(res, df_names){
    match(res, df_names)
}

create_list_with_index = function(data_names){
    res = as.list(seq_along(data_names))
    names(res) = data_names
    res
}

###

create_list_with_symbols = function(data_names){
    res = lapply(data_names, as.symbol)
    names(res) = data_names
    res
}

create_list_with_names = function(data_names){
    res = as.list(data_names)
    names(res) = data_names
    res
}





####



create_name_sequence = function(from, to){
    patt1 = gsub("^(.+?)([\\d]+)$", "\\1", from, perl = TRUE)
    patt2 = gsub("^(.+?)([\\d]+)$", "\\1", to, perl = TRUE)
    (patt1 == patt2) || stop("'columns range selection': start and end variables begin from different patterns: '", patt1, "', '", patt2,"'.")
    digits1 = gsub("^(.+?)([\\d]+)$", "\\2", from, perl = TRUE)
    digits2 = gsub("^(.+?)([\\d]+)$", "\\2", to, perl = TRUE)
    padding = 0
    if((substr(digits1,1,1)=="0" || substr(digits2,1,1)=="0") &&
       !(substr(digits1,1,1)=="0" && nchar(digits1)==1 && substr(digits2,1,1)!=0)){
        (nchar(digits1) == nchar(digits2)) ||
            stop("'columns' range selection: invalid use of the '%to%' convention. For zero-padded numbers numeric part of the names must be the same length but: '",
                 from, ", '", to, "'.")
        padding = nchar(digits1)
    }
    digits1 = as.numeric(digits1)
    digits2 = as.numeric(digits2)
    (digits1<=digits2) || stop("'columns' range selection: name of start variables greater than name of end variables: '", from,"' > '",to,"'.")
    all_digits = digits1:digits2
    if(padding>0) all_digits = formatC(all_digits, width = padding, format = "d", flag = "0")
    res = paste0(patt1, all_digits)
    unlist(res, recursive = TRUE, use.names = TRUE)
}




########################################################

#' @rdname columns
#' @export
rows = function(data, ...){
    UseMethod("rows")
}


#' @export
rows.data.frame = function(data, ...){
    curr_names = names(substitute(list(...)))
    if(!is.null(curr_names)){
        if(any(c("by", "keyby") %in% curr_names)){
            stop("'rows': you try to use 'by' or 'keyby'. Sorry, but grouped filtering is not yet supported.")
        }
        curr_names = curr_names[curr_names!=""][[1]]
        stop(sprintf("'rows': it seems you use '=' instead of '==': %s.", curr_names))
    }

    parent_frame = parent.frame()
    # if data is expression we want to calculate it only once
    data = force(data)
    # NULL is just a placeholder
    expr = substitute(
        NULL[Reduce(f = '&', list(...)),]
    )
    eval_in_parent_frame(data, expr, frame = parent_frame)

}

#' @export
rows.etable = function(data, ...){
    data_class = class(data)
    data = as.data.table(data)
    res = eval.parent(
        substitute(maditr::rows(data, ...))
    )
    setDF(res)
    class(res) = data_class
    res
}




#########

