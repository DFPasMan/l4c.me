mongoose = require 'mongoose'
mongooseTypes = require 'mongoose-types'
mongooseTypes.loadTypes mongoose

helpers = require '../lib/helpers'
_ = underscore = require 'underscore'
im = require 'imagemagick'
invoke = require 'invoke'
model_tag = require './tag'
fs = require 'fs'
util = require 'util'
nodejs_path = require 'path'

Schema = mongoose.Schema
ObjectId = Schema.ObjectId
Email = mongoose.SchemaTypes.Email

methods =
	set_slug: (next) ->
		doc = this
		slug = helpers.slugify doc.name
		new_slug = slug + ''
		i = 1

		model.count slug: new_slug, (err, count) ->
			if count == 0
				doc.slug = new_slug
				doc.save (err) ->
					return next err  if err
					next new_slug
			
			else
				slug_lookup = (err, count) ->
					if count == 0
						doc.slug = new_slug
						return doc.save (err) ->
							return next err  if err
							next doc.slug
					
					i++
					new_slug = "#{slug}-#{i}"
					model.count slug: new_slug, slug_lookup
				
				slug_lookup err, count

	# tags - create tag and update tags count
	set_tags: (tags, next) ->
		doc = this
		queue = null
		photo_tags = []

		if _.isArray tags
			tags = tags
		else if _.isString tags
			tags = _.str.trim tags
			tags = if tags.length > 0 then tags.split(' ') else []
		else if !tags.length
			return next()

		_.each tags, (tag, index) ->
			console.log "each tags: ", tag
			fn = (data, callback) ->
				name = tag
				slug = helpers.slugify tag
				model_tag.findOne slug: slug, (err, tag) ->
					return callback err  if err

					if tag
						console.log "tag update:start #{tag.name}"
						tag.count = tag.count + 1
						tag.save (err) ->
							console.log "tag update:save #{tag.name}"
							photo_tags.push tag
							callback err
					else
						console.log "tag create:start #{name}"
						tag = new model_tag
						tag.name = name
						tag.slug = slug
						tag.count = 1
						tag.save (err) ->
							console.log "tag create:save #{tag.name}"
							photo_tags.push tag
							callback err
			
			if !index
				queue = invoke fn
			else
				queue.and fn

		queue.then (data, callback) ->
			return callback()  if !photo_tags.length

			console.log "photo update tags"
			photo_tags = _.sortBy photo_tags, (tag) -> tag.name
			doc._tags = _.pluck photo_tags, '_id'
			doc.save callback
		
		queue.rescue next
		queue.end null, (data) -> next null, photo_tags

	resize_photo: (size, next) ->
		if _.isString size
			size = helpers.image.sizes[size]
		else if _.isObject size
			size = size
		else
			return next new Error 'Image size required'

		doc = this
		path = nodejs_path.normalize "#{__dirname}/../../public/uploads/#{doc._id}_#{size.size}.#{doc.ext}"

		im[size.action]
			dstPath: path
			filter: 'Cubic'  #  Lagrange is only available on v6.3.7-1
			format: doc.ext
			height: size.height
			srcPath: nodejs_path.normalize "#{__dirname}/../../public/uploads/#{doc._id}_o.#{doc.ext}"
			width: size.width
		, (err, stdout, stderr) ->
			console.log "photo resize #{size.size}"
			next err, path

	resize_photos: (next) ->
		doc = this
		queue = invoke()
		index = 0
		
		_.each helpers.image.sizes, (size, key) ->
			if !index
				queue = invoke (data, callback) -> doc.resize_photo size, callback
			else
				queue.and (data, callback) -> doc.resize_photo size, callback
			
			index++

		queue.rescue next
		queue.end null, (data) -> next(null, data)

	upload_photo: (file, next) ->
		console.log 'photo upload', file.path

		doc = this
		upload_path = nodejs_path.normalize "#{__dirname}/../../public/uploads/#{doc._id}_o.#{doc.ext}"

		alternate_upload = (path1, path2) ->
			origin = fs.createReadStream path1
			upload = fs.createWriteStream path2
			util.pump origin, upload, (err) ->
				fs.unlink path1, (err) -> next err

		fs.rename file.path, upload_path, (err) ->
			return alternate_upload file.path, upload_path if err
			next err

	pretty_date: () ->
		helpers.pretty_date this.created_at

comment = new Schema
	_user:
		type: ObjectId
		ref: 'user'
	body:
		type: String
		required: true
	created_at:
		default: Date.now
		type: Date
	guest:
		default: true
		type: Boolean
	user:
		name: String
		email: Email

comment.virtual('pretty_date').get methods.pretty_date


photo = new Schema
	_tags: [
		type: ObjectId
		ref: 'tag'
	]
	_user:
		type: ObjectId
		ref: 'user'
		required: true
	comments: [ comment ]
	created_at:
		default: Date.now
		required: true
		type: Date
	description: String
	ext:
		type: String
		enum: ['gif', 'jpg', 'png']
	name:
		required: true
		type: String
	random:
		default: Math.random
		index: true
		set: (v) -> Math.random()
		type: Number
	# sizes:
	# 	l: String
	# 	m: String
	# 	s: String
	# 	t: String
	# 	o: String
	slug:
		# required: true
		type: String
		unique: true
	views:
		default: 0
		type: Number

# virtual: pretty_date
photo.virtual('pretty_date').get methods.pretty_date


# photo.pre 'save', middleware.pre_slug
# photo.pre 'save', (next) ->
# 	if _.isUndefined this.slug
# 		this.slug = this._id
	
# 	next()


photo.methods.set_slug = methods.set_slug
photo.methods.set_tags = methods.set_tags
photo.methods.resize_photo = methods.resize_photo
photo.methods.resize_photos = methods.resize_photos
photo.methods.upload_photo = methods.upload_photo

module.exports = model = mongoose.model 'photo', photo