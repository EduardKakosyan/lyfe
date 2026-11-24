import LyfeKit

// Prints every name the catalogue asks the backend for an icon by, one a
// line, for `lyfe-server queue-icons` to have them drawn ahead of time
// (deploy/spark/draw-icons.sh).
for name in FoodCatalogue.iconNames {
    print(name)
}
