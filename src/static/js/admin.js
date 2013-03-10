var admin = angular.module('admin', ['ngResource', 'ngCookies']);

admin.config(function($routeProvider, $locationProvider){
    $routeProvider.when('/', {redirectTo: '/streams'});
    $routeProvider.when('/status', {controller: 'StatusCtrl', templateUrl: '/status.html'});
    $routeProvider.when('/streams', {controller: 'ListCtrl', templateUrl: '/streams.html'});
    $routeProvider.when('/streams/add', {controller: 'AddCtrl', templateUrl: '/streams-add.html'});
});

admin.factory('Stream', function($resource){
    return $resource('/stream/:id', {'id': '@id'});
});

admin.controller('ListCtrl', function($scope, Stream){
    $scope.searchText = '';
    $scope.streams = Stream.query();

    $scope.remove = function(stream) {
        stream.$delete(function(){
            $scope.streams = Stream.query();
        });
    };
});

admin.controller('AddCtrl', function($scope, Stream, $location){
    $scope.stream = {};

    $scope.$watch('stream', function(){
        $scope.error = null;
    }, true);

    $scope.add = function() {
        Stream.save($scope.stream, function(){
            $location.path('/streams');
        }, function(http){
            $scope.error = http.status;
        });
    };
});

admin.controller('StatusCtrl', function($scope){

});
