# Rivets.Binding
# --------------

# A single binding between a model attribute and a DOM element.
class Rivets.Binding
  # All information about the binding is passed into the constructor; the
  # containing view, the DOM node, the type of binding, the model object and the
  # keypath at which to listen for changes.
  constructor: (@view, @el, @type, @keypath, @options = {}) ->
    @formatters = @options.formatters || []
    @objectPath = []
    @dependencies = []
    @setBinder()
    @setModel()

  setBinder: =>
    unless @binder = @view.binders[@type]
      for identifier, value of @view.binders
        if identifier isnt '*' and identifier.indexOf('*') isnt -1
          regexp = new RegExp "^#{identifier.replace('*', '.+')}$"
          if regexp.test @type
            @binder = value
            @args = new RegExp("^#{identifier.replace('*', '(.+)')}$").exec @type
            @args.shift()

    @binder or= @view.binders['*']
    @binder = {routine: @binder} if @binder instanceof Function

  setModel: =>
    interfaces = (k for k, v of @view.adapters)
    tokens = Rivets.KeypathParser.parse @keypath, interfaces, '.'

    @rootKey = tokens.shift()
    @key = tokens.pop()
    @objectPath ?= []

    model = @view.adapters[@rootKey.interface].read @view.models, @rootKey.path

    for token, index in tokens
      current = @view.adapters[token.interface].read model, token.path

      if @objectPath[index]?
        if current isnt @objectPath[index]
          @view.adapters[token.interface].unsubscribe model, token.path, @setModel
          @view.adapters[token.interface].subscribe current, token.path, @setModel
      else
        @view.adapters[token.interface].subscribe model, token.path, @setModel

      model = current

    if @model and @model isnt model
      @view.adapters[@key.interface].unsubscribe @model, @key.path, @sync
      @view.adapters[@key.interface].subscribe model, @key.path, @sync
      @model = model
      @sync()
    else
      @model = model
      
  # Applies all the current formatters to the supplied value and returns the
  # formatted value.
  formattedValue: (value) =>
    for formatter in @formatters
      args = formatter.split /\s+/
      id = args.shift()

      formatter = if @model?[id] instanceof Function
        @model[id]
      else
        @view.formatters[id]

      if formatter?.read instanceof Function
        value = formatter.read value, args...
      else if formatter instanceof Function
        value = formatter value, args...

    value

  # Returns an event handler for the binding around the supplied function.
  eventHandler: (fn) =>
    handler = (binding = @).view.config.handler
    (ev) -> handler.call fn, @, ev, binding

  # Sets the value for the binding. This Basically just runs the binding routine
  # with the suplied value formatted.
  set: (value) =>
    value = if value instanceof Function and !@binder.function
      @formattedValue value.call @model
    else
      @formattedValue value

    @binder.routine?.call @, @el, value

  # Syncs up the view binding with the model.
  sync: =>
    @set if @key
      @view.adapters[@key.interface].read @model, @key.path
    else
      @model

  # Publishes the value currently set on the input element back to the model.
  publish: =>
    value = Rivets.Util.getInputValue @el

    for formatter in @formatters.slice(0).reverse()
      args = formatter.split /\s+/
      id = args.shift()

      if @view.formatters[id]?.publish
        value = @view.formatters[id].publish value, args...

    @view.adapters[@key.interface].publish @model, @key.path, value

  # Subscribes to the model for changes at the specified keypath. Bi-directional
  # routines will also listen for changes on the element to propagate them back
  # to the model.
  bind: =>
    @binder.bind?.call @, @el
    @view.adapters[@key.interface].subscribe(@model, @key.path, @sync) if @key
    @sync() if @view.config.preloadData

    if @options.dependencies?.length
      for dependency in @options.dependencies
        interfaces = (k for k, v of @view.adapters)
        prefix = dependency[0] in interfaces
        root = if prefix then dependency[0] else '.'
        path = if prefix then dependency.substr(1) else dependency
        tokens = Rivets.KeypathParser.parse path, interfaces, root
        key = tokens.pop()

        model = @model

        for token in tokens
          model = @view.adapters[token.interface].read model, token.path

        @view.adapters[key.interface].subscribe model, key.path, @sync
        @dependencies.push [model, key]

  # Unsubscribes from the model and the element.
  unbind: =>
    @binder.unbind?.call @, @el
    @view.adapters[@key.interface].unsubscribe(@model, @key.path, @sync) if @key

    if @dependencies.length
      for dep in @dependencies
        @view.adapters[dep[1].interface].unsubscribe dep[0], dep[1].path, @sync

      @dependencies = []

  # Updates the binding's model from what is currently set on the view. Unbinds
  # the old model first and then re-binds with the new model.
  update: (models = {}) =>
    if models[@rootKey.path]
      @view.adapters[@key.interface].unsubscribe(@model, @key.path, @sync) if @key
      @setModel()
      @view.adapters[@key.interface].subscribe(@model, @key.path, @sync) if @key
      @sync()

    @binder.update?.call @, models

# Rivets.ComponentBinding
# -----------------------

# A component view encapsulated as a binding within it's parent view.
class Rivets.ComponentBinding extends Rivets.Binding
  # Initializes a component binding for the specified view. The raw component
  # element is passed in along with the component type. Attributes and scope
  # inflections are determined based on the components defined attributes.
  constructor: (@view, @el, @type) ->
    @component = Rivets.components[@type]
    @attributes = {}
    @inflections = {}

    for attribute in @el.attributes or []
      if attribute.name in @component.attributes
        @attributes[attribute.name] = attribute.value
      else
        @inflections[attribute.name] = attribute.value

  # Intercepts `Rivets.Binding::sync` since component bindings are not bound to
  # a particular model to update it's value.
  sync: ->

  # Returns an object map using the component's scope inflections.
  locals: (models = @view.models) =>
    result = {}

    for key, inverse of @inflections
      result[key] = (result[key] or models)[path] for path in inverse.split '.'

    result[key] ?= model for key, model of models
    result

  # Intercepts `Rivets.Binding::update` to be called on `@componentView` with a
  # localized map of the models.
  update: (models) =>
    @componentView?.update @locals models

  # Intercepts `Rivets.Binding::bind` to build `@componentView` with a localized
  # map of models from the root view. Bind `@componentView` on subsequent calls.
  bind: =>
    if @componentView?
      @componentView?.bind()
    else
      el = @component.build.call @attributes
      (@componentView = new Rivets.View(el, @locals(), @view.options)).bind()
      @el.parentNode.replaceChild el, @el

  # Intercept `Rivets.Binding::unbind` to be called on `@componentView`.
  unbind: =>
    @componentView?.unbind()

# Rivets.TextBinding
# -----------------------

# A text node binding, defined internally to deal with text and element node
# differences while avoiding it being overwritten.
class Rivets.TextBinding extends Rivets.Binding
  # Initializes a text binding for the specified view and text node.
  constructor: (@view, @el, @type, @keypath, @options = {}) ->
    @formatters = @options.formatters || []
    @dependencies = []
    @setModel()

  # A standard routine binder used for text node bindings.
  binder:
    routine: (node, value) ->
      node.data = value ? ''

  # Wrap the call to `sync` in fat-arrow to avoid function context issues.
  sync: =>
    super
