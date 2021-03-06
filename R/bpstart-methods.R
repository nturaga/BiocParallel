### =========================================================================
### ClusterManager object: ensures started clusters are stopped
### -------------------------------------------------------------------------

.ClusterManager <- local({
    ## package-global registry of backends; use to avoid closing
    ## socket connections of unreferenced backends during garbage
    ## collection -- bpstart(MulticoreParam(1)); gc(); gc()
    uid <- 0
    env <- environment()
    list(add = function(cluster) {
        uid <<- uid + 1L
        cuid <- as.character(uid)
        env[[cuid]] <- cluster          # protection
        cuid
    }, drop = function(cuid) {
        rm(list=cuid, envir=env)
        invisible(NULL)
    }, get = function(cuid) {
        env[[cuid]]
    }, ls = function() {
        cuid <- setdiff(ls(env), c("uid", "env"))
        cuid[order(as.integer(cuid))]
    })
})

### =========================================================================
### bpstart() methods
### -------------------------------------------------------------------------

setMethod("bpstart", "ANY", function(x, ...) invisible(x))

setMethod("bpstart", "missing",
    function(x, ...)
{
    x <- registered()[[1]]
    bpstart(x)
})

##
## .bpstart_impl: common functionality after bpisup()
##

.bpstart_error_handler <-
    function(x, response, id)
{
    value <- lapply(response, function(elt) elt[["value"]][["value"]])
    if (!all(bpok(value))) {
        on.exit(try(bpstop(x)))
        stop(
            "\nbpstart() ", id, " error:\n",
            conditionMessage(.error_bplist(value))
        )
    }
}

.bpstart_set_logging <-
    function(x)
{
    cluster <- bpbackend(x)

    value <- .EXEC(NULL, .log_load, list(bplog(x), bpthreshold(x), TRUE))
    .send_all(cluster, value)
    response <- .recv_all(cluster)

    .bpstart_error_handler(x, response, "set_logging")
    invisible(x)
}

.bpstart_set_rng_seed <-
    function(x)
{
    cluster <- bpbackend(x)
    rng_seed <- bpRNGseed(x)

    ##
    ## from parallel::clusterSetRNGStream
    ##
    oldseed <-
        if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) {
            get(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
        } else NULL
    RNGkind("L'Ecuyer-CMRG")
    if (!is.null(rng_seed))
        set.seed(rng_seed)
    nc <- length(cluster)
    seeds <- vector("list", nc)
    seeds[[1L]] <- .Random.seed
    for (i in seq_len(nc - 1L))
        seeds[[i + 1L]] <- nextRNGStream(seeds[[i]])
    if (!is.null(oldseed)) {
        assign(".Random.seed", oldseed, envir = .GlobalEnv)
    } else rm(.Random.seed, envir = .GlobalEnv)

    for (i in seq_along(cluster)) {
        expr <- substitute(
            assign(".Random.seed", seed, envir = .GlobalEnv),
            list(seed = seeds[[i]])
        )
        value <- .EXEC(i, eval, list(expr))
        .send_to(cluster, i, value)
    }
    response <- .recv_all(cluster)

    .bpstart_error_handler(x, response, "set_rng_seed")
    invisible(x)
}

.bpstart_set_finalizer <-
    function(x)
{
    if (length(x$.uid) == 0L) {
        finalizer_env <- as.environment(list(self=x$.self))
        reg.finalizer(
            finalizer_env, function(e) bpstop(e[["self"]]), onexit=TRUE
        )
        x$.finalizer_env <- finalizer_env
    }
    x$.uid <- .ClusterManager$add(bpbackend(x))

    invisible(x)
}

.bpstart_impl <-
    function(x)
{
    ## common actions once bpisup(backend)
    
    ## logging
    if (bplog(x))
        .bpstart_set_logging(x)

    ## random numbers
    if (!is.null(bpRNGseed(x)))
        .bpstart_set_rng_seed(x)

    ## clean up when x left open
    .bpstart_set_finalizer(x)
}
