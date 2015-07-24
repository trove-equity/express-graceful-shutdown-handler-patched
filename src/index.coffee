createDomain = require('domain').create

_            = require 'lodash'
onFinished   = require 'on-finished'

class ExpressGracefulShutdown
  constructor: (options) ->
    # Parse options
    @domainEnabled               = options.domainEnabled
    @domainIdFunc                = options.domainIdFunc

    @onExceptionFn               = options.onExceptionFn
    @shutdownGraceSeconds        = options.shutdownGraceSeconds
    @inShutdownRespondWithStatus = options.inShutdownRespondWithStatus

    # Initialize vars
    @gracefulShutdownMode   = false
    @pendingRequestsCount   = 0
    @pendingExceptionsCount = 0

    # Setup
    process.on 'uncaughtException', @exceptionHandler()

  # Middleware
  middleware: () =>
    (req, res, next) =>
      domain = @bindToDomain req, res

      @pendingRequestsCount += 1
      onFinished res, @requestFinishHandler

      if @gracefulShutdownMode
        return res.sendStatus @inShutdownRespondWithStatus

      @runCallbackInDomain domain, next
      domain.run -> next()

  # Domains
  bindReqResToDomain: (req, res) ->
    return unless @domainEnabled

    domain = createDomain()
    domain.id = @domainIdFunc req

    domain.add(req)
    domain.add(res)
    domain.on 'error', @exceptionHandler(res)

    domain

  runCallbackInDomain: (domain, callback) ->
    return callback() unless domain?

    domain.run -> callback()

  # Event Handlers
  exceptionHandler: (res) ->
    (exc) =>
      if res
        # onFinished handler will fire
        res.sendStatus 500
      else
        # Correct for domain runaway request.
        @pendingRequestsCount  -= 1

      # Go into shutdown mode.
      @gracefulShutdownMode = true
      @startHardKillTimer()

      @pendingExceptionsCount += 1
      @onExceptionFn exc, () =>
        @pendingExceptionsCount -= 1
        @applyKillConditions()

  requestFinishHandler: () =>
    @pendingRequestsCount -= 1
    @applyKillConditions()

  # Hard kill timer
  startHardKillTimer: () ->
    return if @hardKillTimer?

    @hardKillTimer = setTimeout () =>
      @killProcess()
    , @shutdownGraceSeconds * 1000

  # Actions
  applyKillConditions: () ->
    console.log "queue <#{@pendingRequestsCount}, #{@pendingExceptionsCount}>"

    return if not @gracefulShutdownMode
    return if @pendingRequestsCount   > 0
    return if @pendingExceptionsCount > 0

    @killProcess()

  killProcess: () ->
    process.exit(1)


reqId = 0
module.exports = (options) ->
  defaultOptions = {
    domainEnabled: true
    domainIdFunc: (req) -> return reqId++

    onExceptionFn: (exc, callback) ->
      console.error exc
      callback()
    shutdownGraceSeconds: 15
    inShutdownRespondWithStatus: 503
  }

  new ExpressGracefulShutdown(_.assign(defaultOptions, options)).middleware()
