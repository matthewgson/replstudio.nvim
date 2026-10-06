library(ggplot2)
# a comment

x <- 1:10
f <- function(a, b = 2) {
  y <- a + b

  y * 2
}
df <- mtcars |>
  subset(cyl > 4) |>
  transform(kpl = mpg * 0.425)
ggplot(df, aes(wt, mpg)) +
  geom_point() +
  facet_wrap(~cyl)
a <- 1; b <- 2
for (i in 1:3) {
  print(i)
}
if (x[1] > 0) {
  "pos"
} else {
  "neg"
}
